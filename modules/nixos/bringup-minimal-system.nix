{ config, lib, pkgs, modulesPath, ndh ? null, ... }:
{
  # Minimal NixOS system for bringup — installs into ZFS pools, boots, then
  # cloud-init fetches and activates the full system at first boot.

  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./bringup-cloud-init.nix
  ];

  # SSH key management for cloud-init store access
  # The system decrypts the full ssh-keys.yaml via sops (defined in .common.d/sops.nix),
  # then we extract the rke2-cluster key for cloud-init to use for nix copy --from ssh://

  # Extract SSH key from decrypted keys.yaml for cloud-init
  systemd.services.bringup-extract-ssh-key = {
    description = "Extract SSH key for cloud-init remote store access";
    wantedBy = [ "multi-user.target" ];
    after = [ "sops-install-secrets.service" ];
    requires = [ "sops-install-secrets.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail

      KEYS_YAML="/run/secrets/nix-darwin-home/ssh-keys.yaml"
      SSH_DIR="/root/.ssh"
      KEY_NAME="rke2-cluster"

      if [[ ! -r "$KEYS_YAML" ]]; then
        echo "[bringup-extract-ssh-key] ERROR: ssh-keys.yaml not found at $KEYS_YAML" >&2
        exit 1
      fi

      mkdir -p "$SSH_DIR"
      chmod 700 "$SSH_DIR"

      # Extract the private key using yq
      if ! ${pkgs.yq-go}/bin/yq eval '.profiles.committed."'"$KEY_NAME"'".private' "$KEYS_YAML" > "$SSH_DIR/$KEY_NAME"; then
        echo "[bringup-extract-ssh-key] ERROR: Failed to extract $KEY_NAME from $KEYS_YAML" >&2
        exit 1
      fi

      chmod 600 "$SSH_DIR/$KEY_NAME"

      # Extract public key
      if ! ${pkgs.yq-go}/bin/yq eval '.profiles.committed."'"$KEY_NAME"'".public' "$KEYS_YAML" > "$SSH_DIR/$KEY_NAME.pub"; then
        echo "[bringup-extract-ssh-key] ERROR: Failed to extract $KEY_NAME.pub from $KEYS_YAML" >&2
        exit 1
      fi

      # Format public key properly (add type prefix)
      KEY_TYPE=$(${pkgs.yq-go}/bin/yq eval '.profiles.committed."'"$KEY_NAME"'".type' "$KEYS_YAML")
      PUB_CONTENT=$(cat "$SSH_DIR/$KEY_NAME.pub")
      echo "$KEY_TYPE $PUB_CONTENT" > "$SSH_DIR/$KEY_NAME.pub"
      chmod 644 "$SSH_DIR/$KEY_NAME.pub"

      echo "[bringup-extract-ssh-key] Successfully extracted SSH key: $KEY_NAME"
    '';
  };

  # Disable SSH agent (not needed)
  programs.ssh.startAgent = lib.mkForce false;

  # Override the zfs-nixos-install assertion that requires runtimeSystemPath.
  # For minimal bringup, we don't have a runtime system — activation is deferred to cloud-init.
  assertions = lib.mkForce [ ];

  # Minimal filesystems for bringup — no ZFS datasets, just boot disk
  fileSystems = lib.mkForce {
    "/" = {
      device = "/dev/vda1";
      fsType = "ext4";
    };
  };

  # Essential ZFS support for pool operations
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = lib.mkForce false;
  boot.zfs.devNodes = "/dev/disk/by-id";

  # Network for cloud-init to fetch full system
  networking.useNetworkd = lib.mkForce true;
  networking.useDHCP = lib.mkForce true;
  networking.firewall.enable = lib.mkForce false;

  # Cloud-init for runtime provisioning
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  # Minimal system packages - only essentials for bootstrap
  environment.systemPackages = with pkgs; [
    curl
    zfs
    openssh  # SSH client for nix copy --from ssh://
    age      # For sops age key operations
    sops     # For secrets decryption
  ];

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

  # Minimal boot requirements - no grub since we use systemd-boot
  boot.loader.grub.enable = lib.mkForce false;

  # Disable fonts (no X11/GUI)
  fonts.fontconfig.enable = lib.mkForce false;
}
