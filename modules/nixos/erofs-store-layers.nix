# Canonical layout of the split /nix/store: an ordered stack of prebuilt
# read-only EROFS layers plus one writable ZFS-backed overlay upper.
#
# Single source of truth for the consumers that must agree exactly, or the image
# builds fine and then fails to boot:
#   - zfs-disko-config.nix          (declares the ZFS dataset for the upper)
#   - erofs-store-mount.nix         (runtime fileSystems, one per layer)
#   - bringup-zfs-disk-image.nix    (packs one image per layer, attaches them)
#   - zfs.d/bringup-zfs-disk-images-install.sh (mounts the same stack on the
#     install target before nixos-install)
#
# Same source-vs-projection shape as zfs-pool-disk-map.nix: the list is declared
# once here, every consumer is a projection over it.
{
  # ---- shared by every layer -------------------------------------------------

  # Mount point of the ZFS dataset holding the overlay upper + work dirs.
  rwMountPoint = "/nix/.rw-store";

  # Dataset name, relative to the pool, for the writable upper.
  rwDataset = "nerd/nix/rwstore";

  # The effective store: overlay(lowerdir = the stack, upperdir = the ZFS upper).
  storeMountPoint = "/nix/store";

  # ---- the stack, OLDEST FIRST ----------------------------------------------
  #
  # This order is the order the disks are attached, and the REVERSE of the
  # overlay `lowerdir` order: overlayfs searches lowerdir left to right, so the
  # newest layer has to come first there for a re-packed path to win.
  layers = [
    {
      # Handle for this layer in logs and in its GC root.
      name = "bringup";

      # Filesystem label stamped into the image by mkfs.erofs -L, and the way
      # the runtime finds the disk without caring which virtio slot Tart gave
      # it.  MUST NOT change for this layer: every system generation already
      # installed on a node mounts its lower by this exact label, so renaming it
      # would strand each generation the node can still boot.
      label = "nix-store";

      # Mount point of this read-only layer.
      roMountPoint = "/nix/.ro-store";

      # Image name inside the bundle (<imageName>.img) and the attribute name
      # under `prebuiltImages`.  Kept bare for the same backward-compatibility
      # reason as the label: the darwin materializer tracks this image by
      # `store.img.source`, and renaming it would orphan that marker along with
      # the 2.7 GiB image it points at.
      imageName = "store";
    }
  ];
}
