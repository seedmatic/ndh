{ config, pkgs, lib, hostId, ... }:

let

  cfg = config.zfsOverlays;

  joinMountPoints = prefix: point:
    if point == "/" then
      prefix
    else if prefix == "/" then
      point
    else
      "${prefix}${point}";

  # --- Recursive flattener for datasets ---
  flattenMountpoints = dsSet:
    lib.concatMap (name:
      let
        ds = dsSet.${name};
        this = if ds ? mountpoint && ds.mountpoint != null then [{
          mountpoint = ds.mountpoint;
          options = ds.options or { }; # Always an attrset
        }] else
          [ ];
        # Disko may use `children` or `datasets` for nested datasets
        children = if ds ? children then
          flattenMountpoints ds.children
        else if ds ? datasets then
          flattenMountpoints ds.datasets
        else
          [ ];
      in this ++ children) (lib.attrNames dsSet);

  # Build a mapping from mountpoint -> dataset info (including options)
  mountpointList =
    flattenMountpoints (config.disko.devices.zpool.tank.datasets or { });

  _mountpointMap = lib.listToAttrs (map (ds: {
    name = ds.mountpoint;
    value = ds;
  }) mountpointList);

  mountpointMap = builtins.traceVerbose ''
    -- mountpointMap --
    ${builtins.toJSON _mountpointMap}
    --'' _mountpointMap;

  mountPoints = lib.attrNames mountpointMap;

  _overlayMountPoints = lib.filter (mp:
    let ds = mountpointMap.${mp};
    in ds.options ? "nixos:mount-overlay" && ds.options."nixos:mount-overlay"
    == "true") mountPoints;

  overlayMountPoints = builtins.traceVerbose ''
    -- overlayMountPoints --
    ${builtins.toJSON _overlayMountPoints}
    --'' _overlayMountPoints;

  _zfsMountPoints = lib.filter (mp:
    let ds = mountpointMap.${mp};
    in !(ds.options ? "nixos:mount-overlay" && ds.options."nixos:mount-overlay"
      == "true")) mountPoints;

  zfsMountPoints = builtins.traceVerbose ''
    -- zfsMountPoints --
    ${builtins.toJSON _zfsMountPoints}
    --'' _zfsMountPoints;

  fileSystemsMap = lib.foldl' (a: b: a // b) { }
    config.disko.devices._config.fileSystems.contents;

  zfsLegacyFileSystems = lib.listToAttrs (map (mount: {
    name = "${mount}";
    value = fileSystemsMap.${mount} // {
      neededForBoot = true;
      options = [ "defaults" "X-mount.mkdir" "zfsutil" ];
    };
  }) zfsMountPoints);

  zfsOverlayFileSystems = lib.listToAttrs (map (mount: {
    name = "/mnt/overlays${mount}";
    value = fileSystemsMap.${mount} // {
      neededForBoot = true;
      options = [ "defaults" "X-mount.mkdir" ];
    };
  }) overlayMountPoints);

  overlayFileSystems = lib.listToAttrs (map (mount: {
    name = mount;
    value = {
      fsType = "overlay";
      device = "overlay";
      neededForBoot = true;
      depends = [ "/mnt/overlays/${mount}" ];
      options = [ "defaults" ];
      overlay = {
        lowerdir = [ mount ];
        upperdir = (joinMountPoints "/mnt/overlays" mount) + "/upper";
        workdir = (joinMountPoints "/mnt/overlays" mount) + "/workdir";
      };
    };
  }) overlayMountPoints);

  fileSystems = let
    _value = zfsOverlayFileSystems // overlayFileSystems;
    _json = (builtins.toJSON _value);
  in (builtins.traceVerbose ''
    -- config.fileSystems --
    ${_json}
    --'' _value);

in {

  options.zfsOverlays.override = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description =
      "Whether to override fileSystems definitions at initial boot.";
  };
  config = {

    networking.hostId = lib.mkDefault hostId;

    boot = {
      supportedFilesystems = (lib.mkAfter { zfs = lib.mkForce true; });
      initrd = {
        supportedFilesystems =
          lib.mkAfter { zfs = (lib.mkForce config.zfsOverlays.override); };
      };
      zfs = (lib.mkIf config.zfsOverlays.override {
        forceImportRoot = false;
        devNodes = lib.mkForce "/dev/disk/by-partlabel";
        extraPools = [ "tank" "recover" ];
      });
    };

    # Only enable services and mount filesystems if override is true
    services.zfs = {
      autoScrub.enable = true;
      trim.enable = true;
    };

    services.sanoid = {
      enable = true;
      datasets."tank" = {
        recursive = true;
        yearly = 0;
        monthly = 0;
        weekly = 1;
        daily = 2;
        hourly = 4;
      };
    };

    fileSystems = (lib.mkIf config.zfsOverlays.override 
      (lib.mkMerge [ (lib.mapAttrs (_: fs: lib.mkForce fs) fileSystems) ]));

    containerHost.ctreg.enable = lib.mkIf config.zfsOverlays.override true;

    # Only add extra scripts and shutdown logic if override is true
    environment.systemPackages = [
      pkgs.zfs
      (pkgs.writeShellScriptBin "bootstrap-zfs" ''
        #!/usr/bin/env bash
        set -euo pipefail

        : → mounting NixOS config
        systemctl start lima-nixos-configuration

        : → booting the ZFS based system
        nixos-rebuild boot

        : → running disko
        disko --mode format,mount /var/run/nixos/config/modules/nixos/disko.nix
        zfs umount -a

        : → setting ZFS mountpoints to legacy from fstab
        fstab="/nix/var/nix/profiles/system/etc/fstab"
        if [ -r "$fstab" ]; then
          awk '$3 == "zfs" { print $1 }' "$fstab" | while read -r dataset; do
            zfs set mountpoint=legacy "$dataset"
          done
        fi

        : → exporting all ZFS pools
        zpool export -a

        : systemctl reboot
      '')
    ];

    systemd = {
      tmpfiles.rules = [
        # ensure utmp + wtmp exist on the real root under /run
        "f /run/utmp 0664 root utmp -"
        "f /run/wtmp 0664 root utmp -"
      ];

      shutdownRamfs.contents."/etc/systemd/system-shutdown/zpool".source =
        (lib.mkForce (pkgs.writeShellScript "zpool-sync-export-shutdown" ''
          ${pkgs.zfs}/bin/zpool sync
          ${pkgs.zfs}/bin/zpool export -a
        ''));

      shutdownRamfs.storePaths = [ "${pkgs.zfs}/bin/zpool" ];
    };
  };
}
