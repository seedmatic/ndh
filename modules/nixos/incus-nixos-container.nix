# The one way ndh hosts a service in Incus: a NixOS container whose /nix/store is an overlay on
# a ZFS snapshot of nerd-nixos's own store over its EROFS layers (docs/private-binary-cache-spec.adoc,
# _The containers' /nix/store_). attic-nixos and headscale-nixos are its consumers; each adds only its
# own NixOS modules.
#
# Every mount belongs to nerd-nixos — the container cannot mount its own /nix/store before an init
# that lives in it. Per container:
#   * a store overlay: the snapshot's upper on top of the EROFS layers, all FLAT as lowerdir, the
#     container's dataset as upper, passed in as a disk device;
#   * a read-only metadata view of the same lowers with the snapshot's DB copied beside it, which
#     nix inside the container reads as its lower store, and which is NEVER an overlayfs lower.
#
# Why flat, and why `check-mount=false` (measured on bioskop-nixos 2026-10-11, kernel 6.18.55):
# an overlay whose lowerdir is itself an overlay mounts, but the kernel silently falls back to
# `index=off` ("does not support file handles"), which loses the ESTALE refusal of a changed lower.
# Flat lowers keep `index=on`. nix's `check-mount` then refuses the mount, because it wants lowerdir
# to be the lower store's single directory, so it is off. The store unit asserts the mounted lowerdir
# list against the layer contract (/etc/ndh/store-layers.json, rendered by erofs-store-mount.nix)
# instead, and fails hard on a mismatch.
#
# ⚠️ Privileged by default, by the operator's decision of 2026-10-11, against the recommendation:
# the container's root IS nerd-nixos's root. An instance exposed to the fabric (the cache container)
# sets `privileged = false` and runs in its own user namespace, its disk devices shifted.
#
# The container never evaluates a flake. Its system is built here, into nerd-nixos's store, so the
# snapshot `deliver` takes already carries it; the container restarts on it with an empty upper.
# Creating and delivering are the operator's gestures (`ndh-incus-container`).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ndh.incusNixosContainers;
  hostStateVersion = config.system.stateVersion;
  # The layer contract erofs-store-mount.nix renders: the ordered lowerdirs, the options a consumer
  # must find on its mount, and where nerd-nixos's upper is. The flox NRI plugin's pod stores are its
  # second consumer.
  layerContract = "/etc/ndh/store-layers.json";

  inherit (cfg) stateRoot;

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
      # The iptables firewall needs xt_* modules a container cannot load, and nerd-nixos loads them
      # only by chance: after its reboot the firewall unit failed in every container (pkttype).
      networking.nftables.enable = true;
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
    inherit (instance) target privileged;
    dir = "${stateRoot}/${name}";
    dataset = "${cfg.datasetParent}/${name}";
    toplevel = toplevelOf name instance;
    # The same store as the container's, seen from nerd-nixos: `deliver` sets its profile here.
    hostStore = localOverlayStore {
      root = "${stateRoot}/${name}/root";
      lower = "${stateRoot}/${name}/view";
      upper = "${stateRoot}/${name}/upper";
    };
    devices = instance.devices;
    inherit (instance) profiles;
    health.units = map (u: if lib.isString u then { unit = u; } else u) instance.health.units;
  }) cfg.instances;

  storeScript = pkgs.writeShellApplication {
    name = "ndh-incus-container-store";
    runtimeInputs = [
      config.boot.zfs.package
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.yq-go
      pkgs.util-linux
    ];
    text = builtins.readFile ./incus-nixos-container.d/store.sh;
  };

  # The container's LXC pre-start hook: it refuses to start the container without its store, so Incus
  # never autostarts it on an empty /nix. Reached through /run/current-system, which every generation
  # keeps, since raw.lxc outlives the generation that wrote it.
  prestartHook = pkgs.writeShellApplication {
    name = "ndh-incus-container-prestart";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      for store in "$1/root/nix/store" "$1/view/nix/store"; do
        mountpoint -q "$store" || {
          echo "ndh-incus-container-prestart: $store is not mounted — the container does not start without its store" >&2
          exit 1
        }
      done
    '';
  };

  operatorCli = pkgs.writeShellApplication {
    name = "ndh-incus-container";
    runtimeInputs = [
      config.nix.package
      config.virtualisation.incus.package
      config.boot.zfs.package
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.yq-go
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      INSTANCES=${lib.escapeShellArg (builtins.toJSON instanceInfo)}
      PROJECT=${lib.escapeShellArg cfg.project}
      POOL=${lib.escapeShellArg (lib.head config.virtualisation.incus.preseed.storage_pools).name}
      LAYER_CONTRACT=${lib.escapeShellArg layerContract}
      GUEST_LOWER=${lib.escapeShellArg guestLower}
      GUEST_UPPER=${lib.escapeShellArg guestUpper}
      PRESTART_HOOK=/run/current-system/sw/bin/${prestartHook.name}
      STACK_DESCRIPTION=/run/ndh/store-stack.json
      STORE_DEGRADED=/run/ndh/store-degraded
      GCROOTS=/nix/var/nix/gcroots/ndh-containers
      HEALTH_TIMEOUT=${toString cfg.healthTimeout}
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

    toplevels = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      default = lib.mapAttrs (_: info: info.toplevel) instanceInfo;
      description = "Each instance's system toplevel, the one `deliver` sets as its profile: what a check reads to say what reaches a container.";
    };

    stateRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ndh-containers";
      readOnly = true;
      description = "Where each container's directory lives; the store freeze reads the layers each one stacks there.";
    };

    healthTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 180;
      description = "Seconds `converge` gives a delivered container to be RUNNING with its health units active, before it rolls back.";
    };

    datasetParent = lib.mkOption {
      type = lib.types.str;
      # Not `tank/nerd/containers`: podman owns it (modules/nixos/podman.nix).
      default = "tank/nerd/ndh-containers";
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
            privileged = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Whether the container's root is the NixOS guest's root. `false` runs it in its own
                user namespace, every disk device shifted: what a service exposed to the fabric needs,
                so that a compromise of it stays inside the container.
              '';
            };
            target = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              description = ''
                Incus cluster member the instance is created on. Stated, never left to Incus: without
                it, Incus places at random between members with equal load. `null` states a standalone
                Incus, which refuses `--target`. Whether the member is clustered is a runtime fact, so
                `ndh-incus-container create` checks it and refuses either mismatch.
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
              description = ''
                Extra Incus devices (a NIC on the fabric, a data disk), as `incus config device add`
                keys. `type` is required: `create` passes it positionally, as Incus wants it.
              '';
            };
            profiles = lib.mkOption {
              type = lib.types.attrsOf lib.types.package;
              default = { };
              example = lib.literalExpression ''{ "/nix/var/nix/profiles/per-user/root/x" = pkg; }'';
              description = ''
                Nix profiles besides the system's, by their path inside the container, set host side at
                each delivery. Never from the container's own activation: an unprivileged container's root
                cannot write in the host-owned /nix bind.
              '';
            };
            health.units = lib.mkOption {
              type = lib.types.listOf (
                lib.types.either lib.types.str (
                  lib.types.submodule {
                    options = {
                      unit = lib.mkOption { type = lib.types.str; };
                      kind = lib.mkOption {
                        type = lib.types.enum [
                          "active"
                          "conditional"
                        ];
                        default = "active";
                        description = "`conditional` is also healthy when systemd skipped the unit on its condition.";
                      };
                    };
                  }
                )
              );
              default = [ ];
              description = ''
                Units inside the container that `converge` requires active before it keeps a new system;
                a container declaring none is healthy once RUNNING.
              '';
            };
          };
        }
      );
    };
  };

  config = lib.mkIf (cfg.instances != { }) {
    assertions = lib.concatLists (
      lib.mapAttrsToList (
        name: instance:
        lib.concatLists (
          lib.mapAttrsToList (device: keys: [
            {
              assertion = keys ? type;
              message = "ndh.incusNixosContainers.instances.${name}.devices.${device} has no `type`";
            }
            {
              # The container's systemd mounts tmpfs on /run and /tmp at boot, over the device.
              assertion =
                !(lib.any (dir: lib.hasPrefix dir (keys.path or "")) [
                  "/run/"
                  "/tmp/"
                ]);
              message = "ndh.incusNixosContainers.instances.${name}.devices.${device}: path ${keys.path} is under a tmpfs the container mounts at boot";
            }
          ]) instance.devices
        )
      ) cfg.instances
    );

    environment.systemPackages = [
      operatorCli
      prestartHook
    ];

    # The switch alone moves a container to its declared system, and so does a boot.
    systemd.services.ndh-incus-container-converge = {
      description = "Converge ndh's NixOS containers to their declared systems";
      wantedBy = [ "multi-user.target" ];
      after = [
        "incus.service"
        "incus-startup.service"
      ];
      requires = [ "incus.service" ];
      # Never restarted by the switch itself, which would then wait on every container's restart and health.
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe operatorCli} converge";
      };
    };
    # What the switch restarts instead: changed whenever a declared system changes (the CLI carries them), and
    # restarted AFTER the switch's daemon-reload, so it queues the converge on the NEW definitions. An activation
    # script would run before that reload and queue the old ones. It only queues, so the switch never waits.
    systemd.services.ndh-incus-container-converge-trigger = {
      description = "Queue the convergence of ndh's NixOS containers after a switch";
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ operatorCli ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.systemd.package}/bin/systemctl --no-block start ndh-incus-container-converge.service";
      };
    };

    systemd.services = lib.mapAttrs' (
      name: info:
      lib.nameValuePair "ndh-incus-container-store-${name}" {
        description = "Store overlay of the NixOS container ${name}";
        # Wanted, never required, by the autostart: one container's failure must not stop the others,
        # the cluster nodes included. Its own container refuses to start through its pre-start hook.
        wantedBy = [
          "multi-user.target"
          "incus-startup.service"
        ];
        before = [
          "incus.service"
          "incus-startup.service"
        ];
        after = [ "zfs-mount.service" ];
        unitConfig = {
          # The dataset is created by `ndh-incus-container create`, and mounted by zfs-mount, not by a
          # mount unit, so RequiresMountsFor cannot wait for it. Without this the unit ran at the first
          # boot on the root fs, and the dataset then hid that upper (measured on the probe, 2026-10-14).
          ConditionPathIsMountPoint = info.dir;
          # Written by the first `deliver`: before it there is no snapshot to mount.
          ConditionPathExists = "${info.dir}/lower.snapshot";
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStop = [
            "${pkgs.util-linux}/bin/umount ${info.dir}/root/nix/store"
            "${pkgs.util-linux}/bin/umount ${info.dir}/view/nix/store"
          ];
        };
        environment = {
          LAYER_CONTRACT = layerContract;
          CONTAINER_DIR = info.dir;
          CONTAINER_NAME = name;
          CONTAINER_PRIVILEGED = lib.boolToString info.privileged;
        };
        script = lib.getExe storeScript;
      }
    ) instanceInfo;
  };
}
