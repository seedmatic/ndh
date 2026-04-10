# Podman engine configuration for Lima NixOS VM (@codebase)
# This module configures Podman in the VM to act as a remote engine accessible from the host

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;
  zfsOverlaysEnabled = lib.attrByPath [ "zfsOverlays" "override" ] false config;
in
{
  # Enable Podman and containers
  virtualisation = {
    podman = {
      enable = true;

      # Create a `docker` alias for podman, to use it as a drop-in replacement
      dockerCompat = true;

      # Required for containers under podman-compose to be able to talk to each other.
      defaultNetwork.settings.dns_enabled = true;

      # Enable auto-pruning of old images and containers
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ "--all" ];
      };
    };

    containers = {
      enable = true;

      # Container storage configuration optimized for ZFS
      storage.settings = {
        storage = {
          driver = if zfsOverlaysEnabled then "zfs" else "overlay";
          graphroot = "/var/lib/containers/storage";
          runroot = "/run/containers/storage";
        };

        storage.options = lib.mkIf zfsOverlaysEnabled {
          zfs = {
            mountopt = "nodev";
            # Use ZFS dataset for container storage
            fsname = "tank/nerd/containers";
          };
        };
      };

      # Registry configuration
      registries = {
        search = [
          "docker.io"
          "quay.io"
          "registry.fedoraproject.org"
        ];
        insecure = [ "host.containers.internal:5000" ];
        block = [ ];
      };
    };
  };

  # Create ZFS dataset for container storage
  systemd.services.io-nxmatic-nix-darwin-home-podman-zfs-setup = lib.mkIf zfsOverlaysEnabled {
    description = "Setup ZFS dataset for Podman container storage";
    before = [
      "podman.service"
      "containers-storage.service"
    ];
    wantedBy = [ "io-nxmatic-nix-darwin-home-contributed.target" ];
    unitConfig = {
      ConditionPathExists = "/dev/zfs";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecCondition = "${pkgs.zfs}/bin/zpool list -H -o name tank";
    };
    script = ''
      # Skip if pool is not available yet; do not fail boot orchestration.
      if ! ${pkgs.zfs}/bin/zpool list -H -o name tank >/dev/null 2>&1; then
        exit 0
      fi

      # Create ZFS dataset for containers if it doesn't exist
      if ! ${pkgs.zfs}/bin/zfs list tank/nerd/containers >/dev/null 2>&1; then
        ${pkgs.zfs}/bin/zfs create -o mountpoint=/var/lib/containers tank/nerd/containers
        ${pkgs.coreutils}/bin/mkdir -p /var/lib/containers/storage
        ${pkgs.coreutils}/bin/chown root:root /var/lib/containers
        ${pkgs.coreutils}/bin/chmod 755 /var/lib/containers
      fi

      # Ensure run directory exists
      ${pkgs.coreutils}/bin/mkdir -p /run/containers/storage
      ${pkgs.coreutils}/bin/mkdir -p /run/podman
    '';
  };

  systemd.services.io-nxmatic-nix-darwin-home-podman-docker-link = {
    description = "Create symlink for docker compatibility";
    after = [ "podman.socket" ];
    wants = [ "podman.socket" ];
    wantedBy = [ "io-nxmatic-nix-darwin-home-contributed.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eux -o pipefail
      : Create symlink from /var/run/podman/podman.sock to /var/run/docker.sock
      ${pkgs.coreutils}/bin/ln -sf /var/run/podman/podman.sock /var/run/docker.sock
    '';
  };

  # Open firewall for Podman API
  networking.firewall = {
    allowedTCPPorts = [ 2375 ];
    trustedInterfaces = [
      "podman0"
      "cni-podman0"
    ];
  };

  # Add podman-related packages
  environment.systemPackages = with pkgs; [
    podman
    podman-compose
    buildah
    skopeo
    runc
    conmon
    crun
    slirp4netns
    fuse-overlayfs
  ];

  # Configure container networking
  networking.nat = {
    enable = true;
    internalInterfaces = [ "podman0" ];
  };

  # User configuration for podman
  users.users.${cfgUserName} = {
    extraGroups = [
      "wheel"
      "users"
      "podman"
    ];
    subUidRanges = [
      {
        startUid = 100000;
        count = 65536;
      }
    ];
    subGidRanges = [
      {
        startGid = 100000;
        count = 65536;
      }
    ];
  };

  # Create podman group
  users.groups.podman = { };
}
