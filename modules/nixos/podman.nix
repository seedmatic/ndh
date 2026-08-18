# Podman engine configuration for the NixOS VM (@codebase)
# This module configures Podman in the VM to act as a remote engine accessible from the host

{
  config,
  lib,
  pkgs,
  ndhSystemd,
  ...
}:

let
  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;
  zfsOverlaysEnabled = lib.attrByPath [ "zfsOverlays" "enable" ] false config;
  contributedTargetName = ndhSystemd.contributedTargetName;
  podmanZfsSetupUnitName = ndhSystemd.mkUnitName "podman-zfs-setup";
  podmanDockerLinkUnitName = ndhSystemd.mkUnitName "podman-docker-link";
in
{
  # Kernel modules for netavark's nftables firewall driver. On-demand module
  # autoloading is broken on this image, so every nft expression netavark emits
  # must be preloaded at boot — otherwise `nft -f` fails cryptically with
  # "No such file or directory; did you mean table 'mangle' in family ip".
  # (Diagnosed 2026-08-15: base networking needs the *inet* fib = both the v4
  # and v6 halves; published ports need the nat/dnat statement module.)
  boot.kernelModules = [
    "nft_ct" # `ct state` — FORWARD invalid/established rules
    "nft_fib" # base fib (auto-pulled by the fib_* below; kept explicit)
    "nft_fib_ipv4" # `fib daddr type local`: the inet fib needs BOTH the v4 and
    "nft_fib_ipv6" # v6 halves or the base ruleset apply fails — this was the
    "nft_fib_inet" # original breakage (hostport PREROUTING/OUTPUT chains)
    "nft_chain_nat" # nat chain type (postrouting/prerouting/output hooks)
    "nft_nat" # `snat`/`dnat` statements — hostport DNAT for published ports
    "nft_masq" # `masquerade` — POSTROUTING outbound
    "nft_redir" # `redirect`
    "nft_numgen" # multi-backend hostport DNAT (not needed for single backend)
    "nft_reject" # `reject` (not used by the current netavark ruleset; harmless)
  ];

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
  systemd.services.${podmanZfsSetupUnitName} = lib.mkIf zfsOverlaysEnabled {
    description = "Setup ZFS dataset for Podman container storage";
    before = [
      "podman.service"
      "containers-storage.service"
    ];
    wantedBy = [ contributedTargetName ];
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

  systemd.services.${podmanDockerLinkUnitName} = {
    description = "Create symlink for docker compatibility";
    after = [ "podman.socket" ];
    wants = [ "podman.socket" ];
    wantedBy = [ contributedTargetName ];
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
