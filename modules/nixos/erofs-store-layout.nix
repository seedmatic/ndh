# Canonical names for the split /nix/store: a prebuilt read-only EROFS lower
# plus a writable ZFS-backed overlay upper.
#
# Single source of truth for the three consumers that must agree exactly, or
# the image builds fine and then fails to boot:
#   - zfs-disko-config.nix          (declares the ZFS dataset for the upper)
#   - erofs-store-mount.nix         (runtime fileSystems)
#   - zfs.d/bringup-zfs-disk-images-install.sh (mounts the same layout on the
#     install target before nixos-install)
{
  # Filesystem label stamped into the image by mkfs.erofs -L, and the way the
  # runtime finds the disk (/dev/disk/by-label/…) without caring which virtio
  # slot Tart attached it to.
  label = "nix-store";

  # Mount point of the read-only lower (the EROFS image, its own disk).
  roMountPoint = "/nix/.ro-store";

  # Mount point of the ZFS dataset holding the overlay upper + work dirs.
  rwMountPoint = "/nix/.rw-store";

  # Dataset name, relative to the pool, for the writable upper.
  rwDataset = "nerd/nix/rwstore";

  # The effective store: overlay(lower = roMountPoint, upper = rwMountPoint).
  storeMountPoint = "/nix/store";
}
