{ config, lib, pkgs, modulesPath, ndh ? null, ndhSystemd, self, ... }:
let
  ndhContext = if ndh != null then ndh.context else { };
  baseHostName = ndhContext.hostProfile.hostName or "host";
  # Compose the guest identity to match the runtime convention
  # (modules/.common.d/lima-host.nix: "${hostName}-${guestName}", guestName = "nixos").
  # Keeping the suffix here rather than importing lima-host.nix preserves the
  # minimal image's small module surface.
  guestHostName = "${baseHostName}-nixos";
in
{
  # Minimal NixOS system for bringup — installs into ZFS pools, boots, then
  # cloud-init fetches and activates the full system at first boot.
  #
  # TODO(minimal-bringup): strip non-essential runtime material that the
  # image currently inherits from the shared modules:
  #   - linux-builder key references (authorized_keys, builder user, etc.)
  #     — bringup never runs nested builds, only `nix copy` via nix-store.
  #   - any other keys beyond `nix-store` + the authority the split filter
  #     implies (profiles ∋ bringup).
  #   - any module that enables build-time tooling the image does not use
  #     for activation.
  # The bringup profile filter is already in place (profile.names =
  # ["bringup"] below); the residual references live outside the
  # enrichment pipeline and need their own targeted cleanup.

  imports = [
    # NixOS installer scaffolding
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")

    # Profile & user
    "${self}/profile.nix"

    # Secrets (SOPS): local sops.nix drives the bringup decrypt flow,
    # .common.d/sops.nix provides the shared secret declarations.
    ./sops.nix
    "${self}/modules/.common.d/sops.nix"

    # Nix daemon configuration (experimental-features + fleet signing).
    # Cloud-init's `nix copy` needs nix-command + flakes + trust of the
    # fleet signing pub. cache-trust is split common/platform: .common.d
    # holds the walker + composeScript; ./cache-trust.nix wires the
    # NixOS-side systemd oneshot that runs it after sops.
    "${self}/modules/.common.d/nix-settings.nix"
    "${self}/modules/.common.d/cache-trust.nix"
    ./cache-trust.nix

    # SSH identity (keys.yaml access + cert-signed nix-store identity).
    # ssh-keys-enrichment signs the cert-only keys (nix-store, linux-builder)
    # with the mammoth-skate authority and writes the usable keypair + cert
    # under sshPaths.systemKeysDir (/var/lib/ndh/ssh-keys) so cloud-init's
    # `nix copy --from ssh-ng://` can use it.
    "${self}/modules/.common.d/ssh-paths.nix"
    "${self}/modules/.common.d/openssh-policy.nix"
    "${self}/modules/.common.d/nix-store-identity.nix"
    "${self}/modules/.common.d/keys-yaml.nix"
    ./systemd/ssh-keys-enrichment.nix
    ./nix-store-identity.nix

    # Cloud-init + minimal-guest boot scaffolding
    ./systemd/naming.nix
    ./bringup-cloud-init.nix
    ./initrd-emergency.nix
    ./console-serial.nix
    ./boot-loader.nix

    # Storage (ZFS pools + recovery chroot)
    ./zfs.nix
    ./zfs-recovery-chroot.nix
  ];

  networking.hostName = guestHostName;

  # Bringup profile: only the bringup-scope keys are deployed (nix-store
  # for cloud-init's `nix copy --from ssh://`). No user-scope material,
  # no host-scope material — the minimal image boots, fetches, activates.
  profile.names = lib.mkForce [ "bringup" ];

  # mDNS resolution via systemd-resolved. cloud-init's runcmd resolves the
  # remote store hostname (e.g. bioskop.local) via standard NSS + resolved,
  # so enable MulticastDNS both globally (resolver side) and per-link (sender
  # side). cloud-init generates /etc/systemd/network/10-cloud-init-enp0s1.network
  # at runtime, so we add a drop-in directory read by systemd-networkd that
  # flips MulticastDNS on for the cloud-init link without fighting over the
  # base .network file.
  services.resolved = {
    enable = true;
    extraConfig = ''
      MulticastDNS=resolve
      LLMNR=resolve
    '';
  };
  environment.etc."systemd/network/10-cloud-init-enp0s1.network.d/10-mdns.conf".text = ''
    [Network]
    MulticastDNS=yes
  '';

  # Bringup has no login user; the shared sops.nix defaults the ssh-keys secret
  # owner to config.profile.user.name. Override to root for the minimal image.
  sops.secrets."ssh-keys.yaml".owner = lib.mkForce "root";

  # ssh-keys-enrichment lands host-scope privates (nix-store, linux-builder)
  # at sshPaths.systemKeysDir (root-owned, default /var/lib/ndh/ssh-keys). No
  # override needed: cloud-init reads from that path directly. User-scope
  # extraction is effectively a no-op in bringup because there's no user
  # home-manager consumer for the user-scope keys.

  # Ordering for cloud-init: defer cloud-final until every prerequisite is up.
  # This replaces the busy-wait loops that used to live inside the runcmd.
  # ssh-keys-enrichment materializes config.nixStoreIdentity.keyPath +
  # certPath under sshPaths.systemKeysDir, so cloud-init's `nix copy`
  # finds the identity ready without a separate deploy step.
  systemd.services.cloud-final = {
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "sops-install-secrets.service"
      (ndhSystemd.mkServiceName "ssh-keys-enrichment")
    ];
    requires = [
      "sops-install-secrets.service"
      (ndhSystemd.mkServiceName "ssh-keys-enrichment")
    ];
  };

  # Disable SSH agent (not needed)
  programs.ssh.startAgent = lib.mkForce false;

  # Include ssh_config.d/*.conf so cloud-init's `nix copy` resolves the
  # `nix-store.<host>` alias that modules/.common.d/nix-store-identity.nix
  # emits into /etc/ssh/ssh_config.d/75-nix-store.conf. The full runtime
  # gets this from modules/nixos/systemd/openssh.nix; the minimal bringup
  # image intentionally does not import that module and needs its own
  # Include directive.
  programs.ssh.extraConfig = lib.mkAfter ''
    Include ssh_config.d/*.conf
  '';

  # Enable SSH server for emergency access + mammoth-skate cert auth on
  # both sides of the handshake so clients with the CA trust can ssh in
  # without known_hosts pinning and sshd accepts ssh-user certs without
  # per-user authorized_keys churn. The referenced files are materialized
  # by the ssh-keys-enrichment unit (ordered `before sshd.service`) into
  # sshPaths.systemKeysDir.
  services.openssh = {
    enable = true;
    hostKeys = lib.mkForce [ ];  # Disable auto-generated host keys — we use the rdp-host material below.
    settings = {
      PermitRootLogin = "prohibit-password";  # Only allow key-based auth
      HostKey = "${config.sshPaths.systemKeysDir}/${config.sshPaths.keyName}";
      HostCertificate = "${config.sshPaths.systemKeysDir}/${config.sshPaths.keyName}-server-cert.pub";
      TrustedUserCAKeys = "${config.sshPaths.systemKeysDir}/trusted-user-ca.pub";
    };
  };

  # Allow root to use emergency shell without password
  # Set empty password hash so sulogin can grant access
  users.users.root.hashedPassword = "";

  # Add authorized SSH keys for root from keys.yaml via the shared
  # ndh.keysYaml helper (modules/.common.d/keys-yaml.nix). linux-builder
  # powers remote build fan-out during bootstrap; rdp-host is the
  # interactive operator key.
  users.users.root.openssh.authorizedKeys.keys =
    config.ndh.keysYaml.authorizedLinesFor [
      "linux-builder"
      "rdp-host"
    ];

  # Auto-grow ZFS partitions when Lima/Tart resizes disk images.
  # The partition layout constants (ESP size, ZFS type GUID) are defined in
  # zfs-partition-layout.nix and surfaced as zfsOverlays.diskLayout.* options
  # in zfs.nix. The repart config is generated there.
  zfsOverlays.repart.enable = true;

  # Override the zfs-nixos-install assertion that requires runtimeSystemPath.
  # For minimal bringup, we don't have a runtime system — activation is deferred to cloud-init.
  assertions = lib.mkForce [ ];

  # ZFS root filesystem and all datasets - generated by zfs.nix from disko config
  # The disko config (zfs-disko-config.nix) defines all ZFS datasets and their properties.
  # The zfs.nix module extracts filesystem entries from disko and applies them here.
  # Enable ZFS boot configuration and filesystem generation from ./zfs.nix module
  zfsOverlays.enable = true;
  # Disable bootstrap activation in minimal system (no data disks present)
  zfsOverlays.bootstrapActivation.enable = false;

  # Network for cloud-init to fetch full system
  networking.useNetworkd = lib.mkForce true;
  networking.useDHCP = lib.mkForce true;
  networking.firewall.enable = lib.mkForce false;

  # Cloud-init for runtime provisioning
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  # Enable ZFS recovery chroot script
  zfsRecovery.enable = true;

  # Minimal system packages - only essentials for bootstrap
  environment.systemPackages = with pkgs; [
    curl
    zfs
    openssh  # SSH client for nix copy --from ssh://
    age      # For sops age key operations
    sops     # For secrets decryption
  ];

  # Install bringup runtime profile that nixBashTrampoline expects
  # The profile path must match what's configured in the ndh context
  system.activationScripts.bringupProfile = lib.mkIf (ndh != null) (
    let
      ndhContext = ndh.context;
      profilePath = ndhContext.bringupRuntimeProfilePath or null;
      runtimePackage = ndhContext.bringupRuntimePackage or null;
    in
    lib.mkIf (profilePath != null && runtimePackage != null) (
      lib.stringAfter [ "users" ] ''
        mkdir -p "$(dirname "${profilePath}")"
        ln -sfn ${runtimePackage} "${profilePath}"
      ''
    )
  );

  # Disable default packages to minimize closure size
  environment.defaultPackages = lib.mkForce [ ];

  # Disable unnecessary NixOS tools
  system.disableInstallerTools = lib.mkForce true;

  # Disable all documentation to save space
  documentation.enable = lib.mkForce false;
  documentation.nixos.enable = lib.mkForce false;
  documentation.man.enable = lib.mkForce false;
  documentation.info.enable = lib.mkForce false;
  documentation.doc.enable = lib.mkForce false;

  # Disable non-essential services
  services.udisks2.enable = lib.mkForce false;
  xdg.autostart.enable = lib.mkForce false;
  xdg.icons.enable = lib.mkForce false;
  xdg.mime.enable = lib.mkForce false;
  xdg.sounds.enable = lib.mkForce false;

  # Disable unnecessary programs
  programs.command-not-found.enable = lib.mkForce false;
  programs.less.enable = lib.mkForce false;
  programs.nano.enable = lib.mkForce false;

  # Boot loader configuration (systemd-boot, EFI, timeout) via ./boot-loader.nix

  # Disable fonts (no X11/GUI)
  fonts.fontconfig.enable = lib.mkForce false;
}
