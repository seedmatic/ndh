# Runtime mount of the split /nix/store: an ordered stack of prebuilt read-only
# EROFS layers, each on its own disk, plus a writable overlay upper on ZFS.
#
# The layers are produced by erofs-store-image.nix on the build host, so the
# nested guest that assembles the image never materializes the closure as ~260k
# individual files — the measured bottleneck of the bringup build.
#
# Each layer is found by filesystem label rather than device node: Tart decides
# which virtio slot each disk lands in, and that order is not ours to pin.
{ lib, ... }:
let
  storeLayers = import ./erofs-store-layers.nix;
in
{
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
          # overlayfs searches lowerdir left to right, so the newest layer must
          # come first: when a later generation re-packs a path, its copy wins.
          lowerdir = lib.reverseList (map (layer: layer.roMountPoint) storeLayers.layers);
          upperdir = "${storeLayers.rwMountPoint}/upper";
          workdir = "${storeLayers.rwMountPoint}/work";
        };
        neededForBoot = true;
      };
    };
}
