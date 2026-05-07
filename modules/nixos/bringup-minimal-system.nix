{ config, lib, pkgs, modulesPath, ndh ? null, ... }:
{
  # Minimal NixOS system for bringup — installs into ZFS pools, boots, then
  # cloud-init fetches and activates the full system at first boot.

  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./bringup-cloud-init.nix
    ./initrd-emergency.nix
    ./console-serial.nix
    ./boot-loader.nix
    ./zfs.nix
  ];

  # Provide stub ndhSystemd for zfs.nix module compatibility
  _module.args.ndhSystemd = {
    unitPrefix = "";
    mkUnitName = name: name;
    mkServiceName = name: "${name}.service";
    mkTargetName = name: "${name}.target";
    contributedTargetName = "multi-user.target";
  };

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

  # ZFS root filesystem - installed by bringup-zfs-disk-images-install
  # The actual ZFS pool topology and datasets are defined in zfs-disko-config.nix
  fileSystems."/" = {
    device = "tank/nerd/root";
    fsType = "zfs";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/esp-boot";
    fsType = "vfat";
  };

  # Enable ZFS boot configuration from ./zfs.nix module
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
