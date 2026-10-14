# nerd-nixos freezes its own store upper into a read-only ZFS snapshot layer, by command, and its
# initrd builds the store from the stack manifest (docs/store-freeze-spec.adoc).
#
# When enabled, /nix/store stops being the static fileSystems overlay of erofs-store-mount.nix: a
# generation cannot name the frozen layer that holds it, since it was built before its own freeze.
# A stage-1 unit becomes the store mount's only owner and mounts it FLAT (frozen layers, then the
# EROFS layers): a whiteout in a frozen layer must mask the EROFS paths below, and an overlay used
# as a lowerdir would consume its whiteouts. Stage 2 then applies boot.nixStoreMountOpts as it does
# for any store mount.
#
# The nix DB, profiles, gcroots and the build dir stay on their own datasets, continuous; nothing
# here ever rolls back a dataset, since a rollback destroys every later snapshot — the frozen
# layers themselves.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ndh.storeFreeze;
  storeLayers = import ./erofs-store-layers.nix;

  # Newest first, as overlayfs reads lowerdir left to right; the same projection as
  # erofs-store-mount.nix.
  erofsLowers = lib.reverseList (map (layer: layer.roMountPoint) storeLayers.layers);
  rwMount = storeLayers.rwMountPoint;
  # The datasets, read from the mounts that already declare them: one source.
  rwDataset = config.fileSystems.${rwMount}.device;
  dbDataset = config.fileSystems."/nix/var/nix/db".device;

  stackDir = "${rwMount}/stack";
  frozenRoot = "/nix/.frozen";
  runDir = "/run/ndh";
  # Bumped on any change of the manifest's shape: an older initrd refuses a newer version, loudly.
  manifestVersion = "1";

  env = {
    RW_DATASET = rwDataset;
    DB_DATASET = dbDataset;
    RW_MOUNT = rwMount;
    STACK_DIR = stackDir;
    FROZEN_ROOT = frozenRoot;
    EROFS_LOWERS = lib.concatStringsSep ":" erofsLowers;
    RUN_DIR = runDir;
    MANIFEST_VERSION = manifestVersion;
  };
  # Exported: each script reads only some of them.
  exports = lib.concatStrings (
    lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}\n") env
  );

  stackScript = pkgs.writeShellApplication {
    name = "ndh-store-stack";
    runtimeInputs = [ ];
    text = ''
      export SYSROOT=/sysroot
      ${exports}
      ${builtins.readFile ./store-freeze.d/stack.sh}
    '';
  };

  commitScript = pkgs.writeShellApplication {
    name = "ndh-store-commit";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      ${exports}
      ${builtins.readFile ./store-freeze.d/commit.sh}
    '';
  };

  operatorCli = pkgs.writeShellApplication {
    name = "ndh-store";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.util-linux
      config.boot.zfs.package
    ];
    text = ''
      ${exports}
      ${builtins.readFile ./store-freeze.d/cli.sh}
    '';
  };

  # Tools the stage-1 unit calls, by PATH; make-initrd-ng traces each binary's ELF dependencies.
  initrdPath = [
    pkgs.bash
    pkgs.coreutils
    pkgs.gawk
    pkgs.gnused
    pkgs.jq
    pkgs.util-linux
    config.boot.zfs.package
  ];
in
{
  options.ndh.storeFreeze.enable = lib.mkEnableOption ''
    the store freeze: /nix/store built at boot from a stack manifest of frozen ZFS snapshot layers
    over the EROFS layers, and the `ndh-store` gestures
  '';

  config = lib.mkIf cfg.enable {
    # The stage-1 unit owns the store mount instead.
    fileSystems.${storeLayers.storeMountPoint}.enable = lib.mkForce false;

    boot.initrd.systemd.storePaths = [ "${stackScript}/bin/ndh-store-stack" ];
    boot.initrd.systemd.services.ndh-store-stack = {
      description = "Build /nix/store from the stack manifest";
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = [ "/sysroot${rwMount}" ] ++ map (dir: "/sysroot${dir}") erofsLowers;
      };
      after = [ "sysroot.mount" ];
      before = [
        "initrd-fs.target"
        "initrd-find-nixos-closure.service"
      ];
      wantedBy = [ "initrd-fs.target" ];
      requiredBy = [ "initrd-find-nixos-closure.service" ];
      path = initrdPath;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        ExecStart = "${stackScript}/bin/ndh-store-stack";
      };
    };

    environment.systemPackages = [ operatorCli ];

    # A degraded boot never starts nix: its continuous DB may be ahead of the stack it booted on.
    systemd.services.nix-daemon.unitConfig.ConditionPathExists = "!${runDir}/store-degraded";
    systemd.sockets.nix-daemon.unitConfig.ConditionPathExists = "!${runDir}/store-degraded";

    systemd.services = {
      # Loud on purpose: a failed unit and a console message, the store read-only.
      ndh-store-degraded = {
        description = "The store stack fell back: nix is masked, the store read-only";
        unitConfig.ConditionPathExists = "${runDir}/store-degraded";
        wantedBy = [ "multi-user.target" ];
        before = [
          "nix-daemon.socket"
          "nix-daemon.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          StandardOutput = "journal+console";
        };
        script = ''
          ${pkgs.util-linux}/bin/mount -o remount,ro /nix/store || true
          echo "ndh-store: DEGRADED — $(cat ${runDir}/store-degraded)"
          echo "ndh-store: nix-daemon is masked and /nix/store is read-only; repair the manifest, then reboot"
          exit 1
        '';
      };

      ndh-store-freeze-not-done = {
        description = "A requested store freeze is not in this boot's stack";
        unitConfig.ConditionPathExists = "${runDir}/store-freeze-not-done";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          StandardOutput = "journal+console";
        };
        # Reported, never acted on: nothing here freezes.
        script = ''
          echo "ndh-store: the freeze of $(cat ${runDir}/store-freeze-not-done) was requested and is not in this stack"
          exit 1
        '';
      };

      ndh-store-commit = {
        description = "Make the stack this boot was built on the current one";
        after = [ "multi-user.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${commitScript}/bin/ndh-store-commit";
        };
      };
    };
  };
}
