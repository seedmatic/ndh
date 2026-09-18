# Runtime mount of the split /nix/store: a prebuilt read-only EROFS lower on its
# own disk, plus a writable overlay upper on ZFS.
#
# The lower is produced by erofs-store-image.nix on the build host, so the
# nested guest that assembles the image never materializes the closure as
# ~260k individual files — the measured bottleneck of the bringup build.
#
# Found by filesystem label rather than device node: Tart decides which virtio
# slot each disk lands in, and that order is not ours to pin.
{ ... }:
let
  storeLayout = import ./erofs-store-layout.nix;
in
{
  # /nix/store must be mountable in stage 1 to reach stage 2 at all, and
  # nixos/modules/tasks/filesystems/erofs.nix only adds the `erofs` module to
  # the initrd when the filesystem is declared supported there.
  # `overlay` needs no counterpart here — the overlayfs module adds it for any
  # neededForBoot overlay filesystem, and also creates upperdir/workdir.
  boot.initrd.supportedFilesystems.erofs = true;

  fileSystems = {
    ${storeLayout.roMountPoint} = {
      device = "/dev/disk/by-label/${storeLayout.label}";
      fsType = "erofs";
      options = [ "ro" ];
      neededForBoot = true;
    };

    ${storeLayout.storeMountPoint} = {
      overlay = {
        lowerdir = [ storeLayout.roMountPoint ];
        upperdir = "${storeLayout.rwMountPoint}/upper";
        workdir = "${storeLayout.rwMountPoint}/work";
      };
      neededForBoot = true;
    };
  };
}
