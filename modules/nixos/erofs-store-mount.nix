# Runtime mount of the split /nix/store: an ordered stack of prebuilt read-only
# EROFS layers, each on its own disk, plus a writable overlay upper on ZFS.
#
# The layers are produced by erofs-store-image.nix on the build host, so the
# nested guest that assembles the image never materializes the closure as ~260k
# individual files — the measured bottleneck of the bringup build.
#
# Each layer is found by filesystem label rather than device node: Tart decides
# which virtio slot each disk lands in, and that order is not ours to pin.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  storeLayers = import ./erofs-store-layers.nix;

  # overlayfs searches lowerdir left to right, so the newest layer must come first: when a later
  # generation re-packs a path, its copy wins.
  lowerdirs = lib.reverseList (map (layer: layer.roMountPoint) storeLayers.layers);

  # The contract every OTHER overlay on these layers reads: the NixOS containers'
  # (incus-nixos-container.nix), and a candidate for the flox NRI plugin's pod stores. A consumer mounts
  # `lowerdirs` FLAT, never an overlay of them: an overlay as lowerdir mounts, but the kernel then
  # silently falls back to index=off (measured 2026-10-11, kernel 6.18.55), which loses the ESTALE
  # refusal of a changed lower. After mounting, the consumer asserts that the effective options carry
  # `lowerdir=` + `lowerdirs` joined by `:` and every `requiredOptions` entry, and fails hard
  # otherwise.
  layerContract = {
    inherit lowerdirs;
    requiredOptions = [ "index=on" ];
    # The dataset holding nerd-nixos's own upper: the NixOS containers' lowers are a snapshot of it.
    upperRoot = storeLayers.rwMountPoint;
  };
in
{
  environment.etc."ndh/store-layers.json".text = builtins.toJSON layerContract;

  # The layers' upstream paths get their own cache.nixos.org signatures back (the registration loaded
  # them unsigned), so attic's upload filter can skip them: erofs-store-mount.d/upstream-sigs.sh.
  # Best-effort, after the network: it fails nothing, and a boot without network retries later.
  systemd.services.ndh-layer-upstream-sigs = {
    description = "Copy cache.nixos.org's own signatures onto the EROFS layers' upstream paths";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "nix-daemon.service"
    ];
    serviceConfig.Type = "oneshot";
    script = lib.escapeShellArgs (
      [
        (lib.getExe (
          pkgs.writeShellApplication {
            name = "upstream-sigs";
            runtimeInputs = [
              config.nix.package
              pkgs.coreutils
              pkgs.findutils
              pkgs.gawk
            ];
            text = builtins.readFile ./erofs-store-mount.d/upstream-sigs.sh;
          }
        ))
        "https://cache.nixos.org"
        "/var/lib/ndh/layer-upstream-sigs.stamp"
      ]
      ++ lowerdirs
    );
  };

  # /nix/store must be mountable in stage 1 to reach stage 2 at all, and
  # nixos/modules/tasks/filesystems/erofs.nix only adds the `erofs` module to
  # the initrd when the filesystem is declared supported there.
  # `overlay` needs no counterpart here — the overlayfs module adds it for any
  # neededForBoot overlay filesystem, and also creates upperdir/workdir.
  boot.initrd.supportedFilesystems.erofs = true;

  fileSystems =
    (lib.listToAttrs (
      map (layer: {
        name = layer.roMountPoint;
        value = {
          device = "/dev/disk/by-label/${layer.label}";
          fsType = "erofs";
          options = [ "ro" ];
          # Every layer is required to reach stage 2: the closure is spread
          # across the whole stack, so a missing disk is a missing store.
          neededForBoot = true;
        };
      }) storeLayers.layers
    ))
    // {
      ${storeLayers.storeMountPoint} = {
        overlay = {
          lowerdir = lowerdirs;
          upperdir = "${storeLayers.rwMountPoint}/upper";
          workdir = "${storeLayers.rwMountPoint}/work";
        };
        neededForBoot = true;
      };
    };
}
