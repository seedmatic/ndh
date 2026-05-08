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

  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    "${self}/profile.nix"
    ./systemd/naming.nix
    ./sops.nix
    "${self}/modules/.common.d/sops.nix"
    # ssh-keys-enrichment signs the cert-only keys (like `nix-store`) from
    # ssh-keys.yaml using the mammoth-skate authority, materializing a usable
    # top-level `.private` + cert pair that bringup-extract-ssh-key picks up.
    # Pull in the option modules it consumes so bringup doesn't need the full
    # systemd/ aggregator.
    "${self}/modules/.common.d/ssh-paths.nix"
    "${self}/modules/.common.d/openssh-policy.nix"
    ./systemd/ssh-keys-enrichment.nix
    ./bringup-cloud-init.nix
    ./initrd-emergency.nix
    ./console-serial.nix
    ./boot-loader.nix
    ./zfs.nix
    ./zfs-recovery-chroot.nix
  ];

  networking.hostName = guestHostName;

  # Bringup has no login user; the shared sops.nix defaults the ssh-keys secret
  # owner to config.profile.user.name. Override to root for the minimal image.
  sops.secrets."ssh-keys.yaml".owner = lib.mkForce "root";

  # SSH key material for cloud-init remote-store access.
  # Chain: sops-install-secrets → ssh-keys-enrichment → bringup-extract-ssh-key.
  # The enrichment service signs the `nix-store` identity with the
  # mammoth-skate authority and emits the usable keypair into
  # keys.generated.yaml; we extract the top-level `.private` from there.
  systemd.services.${ndhSystemd.mkUnitName "bringup-extract-ssh-key"} = {
    description = "Extract nix-store SSH key for cloud-init remote store access";
    wantedBy = [ "multi-user.target" ];
    after = [ (ndhSystemd.mkServiceName "ssh-keys-enrichment") ];
    requires = [ (ndhSystemd.mkServiceName "ssh-keys-enrichment") ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail

      # keys.generated.yaml is the enriched output (top-level .private for every
      # identity, including cert-signed ones). Path mirrors
      # modules/nixos/systemd/ssh-keys-enrichment.nix (generatedKeysYamlPath).
      KEYS_YAML="/run/secrets/nix-darwin-home/ssh-keys-split.d/keys.generated.yaml"
      SSH_DIR="/root/.ssh"
      KEY_NAME="nix-store"

      if [[ ! -r "$KEYS_YAML" ]]; then
        echo "[bringup-extract-ssh-key] ERROR: enriched keys.generated.yaml not found at $KEYS_YAML" >&2
        exit 1
      fi

      mkdir -p "$SSH_DIR"
      chmod 700 "$SSH_DIR"

      if ! ${pkgs.yq-go}/bin/yq eval '."'"$KEY_NAME"'".private' "$KEYS_YAML" > "$SSH_DIR/$KEY_NAME"; then
        echo "[bringup-extract-ssh-key] ERROR: Failed to extract $KEY_NAME from $KEYS_YAML" >&2
        exit 1
      fi

      chmod 600 "$SSH_DIR/$KEY_NAME"

      # The enriched .public already includes `<type> <blob>` plus an annotated
      # comment, so copy verbatim rather than reassembling.
      if ! ${pkgs.yq-go}/bin/yq eval '."'"$KEY_NAME"'".public' "$KEYS_YAML" > "$SSH_DIR/$KEY_NAME.pub"; then
        echo "[bringup-extract-ssh-key] ERROR: Failed to extract $KEY_NAME.pub from $KEYS_YAML" >&2
        exit 1
      fi
      chmod 644 "$SSH_DIR/$KEY_NAME.pub"

      echo "[bringup-extract-ssh-key] Successfully extracted SSH key: $KEY_NAME"
    '';
  };

  # Disable SSH agent (not needed)
  programs.ssh.startAgent = lib.mkForce false;

  # Enable SSH server for emergency access
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";  # Only allow key-based auth
    };
  };

  # Allow root to use emergency shell without password
  # Set empty password hash so sulogin can grant access
  users.users.root.hashedPassword = "";

  # Add authorized SSH keys for root from keys.yaml
  # This allows SSH access for emergency/debugging
  users.users.root.openssh.authorizedKeys.keys =
    let
      # Load SSH keys from keys.yaml (same pattern as users.nix)
      builderKeys = builtins.fromJSON (
        builtins.readFile (
          pkgs.runCommand "ndh-root-keys.json" { buildInputs = [ pkgs.yq-go ]; } ''
            yq -o=json '.' "${self}/modules/home-manager/ssh.d/keys.yaml" > "$out"
          ''
        )
      );
    in
    lib.filter (k: k != "") [
      # Add linux-builder key for root access (same key used by builder user)
      (
        if builderKeys ? linux-builder && builderKeys.linux-builder ? public then
          "ssh-ed25519 ${builderKeys.linux-builder.public} committed-linux-builder"
        else
          ""
      )
    ];

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
