{
  config,
  lib,
  pkgs,
  modulesPath,
  ndh ? null,
  ndhSystemd,
  self,
  ...
}:
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
  # the operator activates the full system by running nixos-rebuild switch
  # from bioskop targeting this host over SSH.
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
    # ssh-keys-enrichment materializes the nix-store + rdp-host keypairs so
    # bioskop can `nix copy --to` and SSH in during bringup activation.
    "${self}/modules/.common.d/ssh-paths.nix"
    "${self}/modules/.common.d/openssh-policy.nix"
    "${self}/modules/.common.d/nix-store-identity.nix"
    "${self}/modules/.common.d/keys-yaml.nix"
    ./systemd/ssh-keys-enrichment.nix
    ./nix-store-identity.nix

    # Minimal-guest boot scaffolding
    ./systemd/naming.nix
    ./initrd-emergency.nix
    ./console-serial.nix
    ./boot-loader.nix

    # Storage (ZFS pools + recovery chroot)
    ./zfs.nix
    ./zfs-recovery-chroot.nix

    # Tailnet (headscale client + sops schema).  Joining the fleet
    # tailnet during bringup lets the operator `tailscale ssh
    # bioskop-nixos` from any tailnet member while the minimal image
    # is still up, before the full config takes over.  State lives at
    # /var/lib/tailscale/ on the persistent ZFS root, so the full
    # config reuses the same registration on handoff (no double-
    # register, no re-tag).
    #
    # Scope:
    #   - tailnet.nix + headscale-client-wiring.nix: the sops schema
    #     + the `networking.headscale.enable`/`tags`/`serverUrl`
    #     dispatch.  Importing is the opt-in (matches the full-config
    #     path via hosts/host-common.nix).
    #   - headscale.nix (client): the autoconnect unit + the prefixed
    #     `tailscaled-autoconnect.service` that our preauth-key flow
    #     relies on.
    #
    # mDNS (`MulticastDNS=yes` on systemd-resolved, per-link knob on
    # the DHCP ethernet link) is already wired inline below — so we
    # DON'T import modules/nixos/resolved-lan.nix here; doing so would
    # conflict with the bringup-local `services.resolved.extraConfig`.
    "${self}/modules/.common.d/tailnet.nix"
    "${self}/modules/.common.d/headscale-client-wiring.nix"
    ./headscale-client-kind.nix
    ./headscale.nix
  ];

  networking.hostName = guestHostName;

  # Bringup profile: only the bringup-scope keys are deployed.
  profile.names = lib.mkForce [ "bringup" ];

  # No /etc/nixos in the minimal image. The operator activates the full
  # configuration remotely from bioskop via
  # `nixos-rebuild switch --target-host root@<host>-nixos.local`, which ships
  # the prebuilt toplevel over `nix copy` — no guest-side flake evaluation is
  # needed. Once the full runtime is active, modules/nixos/etc-nixos-flake.nix
  # materializes /etc/nixos/flake.nix as a git+file:// forwarding wrapper for
  # day-2 in-guest `nixos-rebuild`.

  # mDNS so bioskop can reach this VM by `<host>-nixos.local`. Both halves
  # must be `yes`, not `resolve`:
  #   - Global `MulticastDNS=yes` enables the announcer (resolved registers
  #     the hostname on 0.0.0.0:5353). `resolve` would only enable inbound
  #     lookups, which is why the VM could ping .local names but nothing
  #     outside could find it.
  #   - Per-link `MulticastDNS=yes` on the DHCP ethernet link actually
  #     attaches the announcer to that interface. systemd-resolved caps the
  #     per-link value at the global setting, so the global must be `yes`
  #     first for the link setting to take effect.
  services.resolved = {
    enable = true;
    extraConfig = ''
      MulticastDNS=yes
      LLMNR=resolve
    '';
  };
  systemd.network.networks."99-ethernet-default-dhcp".networkConfig.MulticastDNS = "yes";

  # Bringup has no login user; the shared sops.nix defaults the ssh-keys secret
  # owner to config.profile.user.name. Override to root for the minimal image.
  sops.secrets."ssh-keys.yaml".owner = lib.mkForce "root";

  # The minimal image does not import modules/nixos/systemd/default.nix, so the
  # `io-nxmatic-nix-darwin-home-contributed.target` that normally pulls the
  # enrichment unit into the boot transaction does not exist here. Wire the
  # dependency directly onto sshd so enrichment runs before sshd starts — the
  # `before = sshd.service` in ssh-keys-enrichment.nix only orders, it does not
  # pull. Without this, sshd's HostKey / HostCertificate / TrustedUserCAKeys
  # paths are not materialized and sshd fails on its first boot.
  systemd.services.sshd = {
    wants = [ (ndhSystemd.mkServiceName "ssh-keys-enrichment") ];
    after = [ (ndhSystemd.mkServiceName "ssh-keys-enrichment") ];
  };

  # Disable SSH agent (not needed)
  programs.ssh.startAgent = lib.mkForce false;

  # Include ssh_config.d/*.conf so outbound SSH (e.g. root-initiated `nix copy`
  # for rescue work) resolves the `nix-store.<host>` alias that
  # modules/.common.d/nix-store-identity.nix emits into
  # /etc/ssh/ssh_config.d/75-nix-store.conf. Read the glob list from the
  # shared opensshPolicy so it stays in sync with the full runtime, which
  # renders the same directives via modules/nixos/systemd/openssh.nix.
  programs.ssh.extraConfig = lib.mkAfter (
    lib.concatMapStringsSep "\n" (g: "Include ${g}") config.opensshPolicy.includeClientGlobs + "\n"
  );

  # Enable SSH server for emergency access + mammoth-skate cert auth on
  # both sides of the handshake so clients with the CA trust can ssh in
  # without known_hosts pinning and sshd accepts ssh-user certs without
  # per-user authorized_keys churn. The referenced files are materialized
  # by the ssh-keys-enrichment unit (ordered `before sshd.service`) into
  # sshPaths.systemKeysDir.
  services.openssh = {
    enable = true;
    hostKeys = lib.mkForce [ ]; # Disable auto-generated host keys — we use the rdp-host material below.
    settings = {
      PermitRootLogin = "prohibit-password"; # Only allow key-based auth
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
  users.users.root.openssh.authorizedKeys.keys = config.ndh.keysYaml.authorizedLinesFor [
    "linux-builder"
    "rdp-host"
  ];

  # Override the zfs-nixos-install assertion that requires runtimeSystemPath.
  # For minimal bringup we have no runtime system — the operator activates the
  # full configuration remotely (nixos-rebuild switch --target-host) once the
  # minimal image is up.
  assertions = lib.mkForce [ ];

  # ZFS root filesystem and all datasets - generated by zfs.nix from disko config
  # The disko config (zfs-disko-config.nix) defines all ZFS datasets and their properties.
  # The zfs.nix module extracts filesystem entries from disko and applies them here.
  # Enable ZFS boot configuration and filesystem generation from ./zfs.nix module
  zfsOverlays.enable = true;
  # Split of responsibilities at first boot:
  #   - systemd-repart initrd units (zfsOverlays.repart.enable, default true
  #     in zfs.nix) own partition growth — pin ESP, grow ZFS partition on
  #     every tank/recover disk.
  #   - zfs-import-<pool>.service (generated by NixOS from
  #     boot.zfs.extraPools) owns pool import.
  #   - zpool-init.service (zfsOverlays.bootstrapActivation.enable, default
  #     true) runs stage-2 after zfs-import.target and owns the residual
  #     reconciliation: `zpool set autoexpand=on`, `zpool online -e` on
  #     every leaf vdev to claim the grown sectors, and dataset mountpoint
  #     normalisation.  Both defaults apply here without further override.

  # zpool-init runs as a systemd initrd unit; the minimal image does not import
  # modules/nixos/default.nix (which is where the full runtime flips this on),
  # so we enable the systemd-based initrd here explicitly.
  boot.initrd.systemd.enable = true;

  # Network for the operator to reach the minimal system over SSH.
  networking.useNetworkd = lib.mkForce true;
  networking.useDHCP = lib.mkForce true;
  networking.firewall.enable = lib.mkForce false;

  # Enable ZFS recovery chroot script
  zfsRecovery.enable = true;

  # Minimal system packages - only essentials for bootstrap
  environment.systemPackages = with pkgs; [
    curl
    zfs
    openssh # SSH client for ad-hoc `nix copy` from this side during rescue
    age # For sops age key operations
    sops # For secrets decryption
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
