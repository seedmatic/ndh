# The one way ndh hosts a service in Incus: a NixOS container whose /nix/store is an overlay on
# nerd-nixos's EROFS layers (docs/private-binary-cache-spec.adoc, _The containers' /nix/store_).
# attic-nixos and headscale-nixos are its tenants; each adds only its own NixOS modules.
#
# Every mount belongs to nerd-nixos — the container cannot mount its own /nix/store before an init
# that lives in it:
#   * a store overlay per container: the EROFS layers FLAT as lowerdir, the container's dataset as
#     upper, passed in as a disk device;
#   * one read-only metadata view of the same layers, which nix inside the container reads as its
#     lower store (paths and DB), and which is NEVER an overlayfs lower.
#
# Why flat, and why `check-mount=false` (measured on bioskop-nixos 2026-10-11, kernel 6.18.55):
# an overlay whose lowerdir is itself an overlay mounts, but the kernel silently falls back to
# `index=off` ("does not support file handles"), which loses the ESTALE refusal of a changed lower.
# Flat lowers keep `index=on`. nix's `check-mount` then refuses the mount, because it wants lowerdir
# to be the lower store's single directory, so it is off. The store unit asserts the mounted lowerdir
# list against the layer contract (/etc/ndh/store-layers.json, rendered by erofs-store-mount.nix)
# instead, and fails hard on a mismatch.
#
# ⚠️ Privileged, by the operator's decision of 2026-10-11, against the recommendation: the
# container's root IS nerd-nixos's root. A tenant that listens on the tailnet (attic) is a root
# shell on the Incus host if it is compromised. Revisit with `shift=true` or a `raw.idmap`.
#
# The container never evaluates a flake. Its system is built here, from the same package set as
# nerd-nixos (so its closure overlaps the layers), and delivered by a host-side `nix copy` into its
# store. Creating, delivering and switching are the operator's gestures (`ndh-incus-container`).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ndh.incusNixosContainers;
  hostStateVersion = config.system.stateVersion;
  # The layer contract erofs-store-mount.nix renders: the ordered lowerdirs and the options a
  # consumer must find on its mount. The flox NRI plugin's pod stores are its second consumer.
  layerContract = "/etc/ndh/store-layers.json";

  stateRoot = "/var/lib/ndh-containers";
  # `current` points at the view of the layer set nerd-nixos booted: `{fingerprint}/nix/{store,var/nix/db}`.
  lowerCurrent = "${stateRoot}/.lower/current";

  # Inside the container: the metadata view and the upper, at fixed paths.
  guestLower = "/nix/.lower";
  guestUpper = "/nix/.upper";
  localOverlayStore =
    {
      root,
      lower,
      upper,
    }:
    "local-overlay://?${
      lib.optionalString (root != null) "root=${root}&"
    }lower-store=local%3Froot%3D${lower}%26read-only%3Dtrue&upper-layer=${upper}&check-mount=false";
  nixFeatures = [
    "nix-command"
    "local-overlay-store"
    "read-only-local-store"
  ];

  # Not nixpkgs' lxc-container.nix: through lxc-instance-common.nix it opens a password-less root
  # login, enables sshd and copies a channel in. The fabric holds no SSH key, and the container
  # evaluates nothing. Kept from it: the container switch, the veth DHCP and the distrobuilder
  # generator.
  guestBase =
    name:
    { config, lib, ... }:
    {
      nixpkgs.pkgs = pkgs;
      boot.isContainer = true;
      networking.hostName = name;
      nix.settings = {
        experimental-features = nixFeatures;
        store = localOverlayStore {
          root = null;
          lower = guestLower;
          upper = guestUpper;
        };
      };
      systemd.network.networks."99-lxc-veth-default-dhcp" = lib.mkIf config.networking.useDHCP {
        matchConfig = {
          Type = "ether";
          Kind = "veth";
          Name = [
            "en*"
            "eth*"
          ];
        };
        DHCP = "yes";
      };
      systemd.additionalUpstreamSystemUnits = [ "systemd-udev-trigger.service" ];
      systemd.packages = [ pkgs.distrobuilder.generator ];
      system.stateVersion = hostStateVersion;
    };

  toplevelOf =
    name: instance:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = null;
      modules = [ (guestBase name) ] ++ instance.modules;
    }).config.system.build.toplevel;

  instanceInfo = lib.mapAttrs (name: instance: {
    inherit name;
    inherit (instance) target;
    dir = "${stateRoot}/${name}";
    dataset = "${cfg.datasetParent}/${name}";
    toplevel = toplevelOf name instance;
    # The same store as the container's, seen from nerd-nixos: deliveries write the delta here.
    hostStore = localOverlayStore {
      root = "${stateRoot}/${name}/root";
      lower = lowerCurrent;
      upper = "${stateRoot}/${name}/upper";
    };
    devices = instance.devices;
  }) cfg.instances;

  lowerScript = pkgs.writeShellApplication {
    name = "ndh-incus-container-lower";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.findutils
      pkgs.yq-go
      pkgs.util-linux
    ];
    text = builtins.readFile ./incus-nixos-container.d/lower.sh;
  };

  storeScript = pkgs.writeShellApplication {
    name = "ndh-incus-container-store";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.yq-go
      pkgs.util-linux
    ];
    text = builtins.readFile ./incus-nixos-container.d/store.sh;
  };

  operatorCli = pkgs.writeShellApplication {
    name = "ndh-incus-container";
    runtimeInputs = [
      config.nix.package
      config.virtualisation.incus.package
      config.boot.zfs.package
      pkgs.coreutils
      pkgs.yq-go
      pkgs.systemd
    ];
    text = ''
      INSTANCES=${lib.escapeShellArg (builtins.toJSON instanceInfo)}
      PROJECT=${lib.escapeShellArg cfg.project}
      LOWER_CURRENT=${lib.escapeShellArg lowerCurrent}
      GUEST_LOWER=${lib.escapeShellArg guestLower}
      GUEST_UPPER=${lib.escapeShellArg guestUpper}
      export NIX_CONFIG="extra-experimental-features = ${lib.concatStringsSep " " nixFeatures}"
      ${builtins.readFile ./incus-nixos-container.d/cli.sh}
    '';
  };
in
{
  options.ndh.incusNixosContainers = {
    project = lib.mkOption {
      type = lib.types.str;
      default = "ndh";
      description = ''
        Incus project of ndh's instances. Never `rke2lab`: a cluster teardown or re-grow must not
        reach an instance that outlives every cluster.
      '';
    };

    datasetParent = lib.mkOption {
      type = lib.types.str;
      default = "tank/nerd/containers";
      description = "ZFS parent of the per-container datasets (upper, work, the container's /nix/var/nix).";
    };

    instances = lib.mkOption {
      default = { };
      description = ''
        NixOS containers hosted on THIS member. Declare an instance only in the configuration of
        the member it runs on: its lowers are that member's EROFS layers, and its dataset is on that
        member's pool.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            target = lib.mkOption {
              type = lib.types.str;
              description = ''
                Incus cluster member the instance is created on. Stated, never left to Incus: without
                it, Incus places at random between members with equal load.
              '';
            };
            modules = lib.mkOption {
              type = lib.types.listOf lib.types.deferredModule;
              default = [ ];
              description = "The service's own NixOS modules, evaluated on nerd-nixos.";
            };
            devices = lib.mkOption {
              type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
              default = { };
              description = "Extra Incus devices (a NIC on the fabric, a data disk), as `incus config device add` keys.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf (cfg.instances != { }) {
    environment.systemPackages = [ operatorCli ];

    systemd.services = {
      ndh-incus-container-lower = {
        description = "Read-only metadata view of the EROFS layers, for the NixOS containers' nix";
        wantedBy = [ "multi-user.target" ];
        before = [ "incus.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        environment = {
          LAYER_CONTRACT = layerContract;
          LOWER_ROOT = "${stateRoot}/.lower";
        };
        script = lib.getExe lowerScript;
      };
    }
    // lib.mapAttrs' (
      name: info:
      lib.nameValuePair "ndh-incus-container-store-${name}" {
        description = "Store overlay of the NixOS container ${name}";
        wantedBy = [ "multi-user.target" ];
        before = [ "incus.service" ];
        after = [
          "zfs-mount.service"
          "ndh-incus-container-lower.service"
        ];
        requires = [ "ndh-incus-container-lower.service" ];
        unitConfig.RequiresMountsFor = [ info.dir ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStop = "${pkgs.util-linux}/bin/umount ${info.dir}/root/nix/store";
        };
        environment = {
          LAYER_CONTRACT = layerContract;
          LOWER_CURRENT = lowerCurrent;
          CONTAINER_DIR = info.dir;
          CONTAINER_NAME = name;
        };
        script = lib.getExe storeScript;
      }
    ) instanceInfo;
  };
}
