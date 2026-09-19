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
#
# Labels are DECLARED here, never derived from the content a layer carries.  A
# content-derived label is impossible for the layer holding a generation's own
# closure: the configuration would name a label computed from a content that
# includes that configuration.  Hence the padded index.
let
  layers = [
    {
      # Handle for this layer in logs and in its GC root.
      name = "001";

      # Filesystem label stamped into the image by mkfs.erofs -L, and the way
      # the runtime finds the disk without caring which virtio slot Tart gave
      # it.  MUST NOT change for this layer: every system generation already
      # installed on a node mounts its lower by this exact label, so renaming it
      # would strand each generation the node can still boot.  Which is also why
      # it has no index suffix while its siblings do.
      label = "nix-store";

      # Mount point of this read-only layer.
      roMountPoint = "/nix/.ro-store";

      # Image name inside the bundle (<imageName>.img) and the attribute name
      # under `prebuiltImages`.  Kept bare for the same backward-compatibility
      # reason as the label: the darwin materializer tracks this image by
      # `store.img.source`, and renaming it would orphan that marker along with
      # the 2.7 GiB image it points at.
      imageName = "store";

      # Historical value, and immovable for the same reason as the label.  Only
      # read when `index` is off — with `index=on` overlayfs stores the lower's
      # UUID in `trusted.overlay.origin` on the upper and refuses a changed lower
      # with ESTALE.  See the kernel config invariant in erofs-store-mount.nix.
      uuid = "9f4a1d2e-6c83-4b17-9e5a-2d7f0c8b3a61";

      # Surfaced in the VM manifest under `storeLayers`, so a disk set is legible
      # without reading this file: `role: prebuilt` says how darwin must treat the
      # image, this says what the layer is FOR.
      purpose = "bringup system closure";
    }
    {
      name = "002";
      label = "nix-store-002";
      roMountPoint = "/nix/.ro-store.002";
      imageName = "store-002";
      uuid = "9f4a1d2e-6c83-4b17-9e5a-2d7f0c8b3b02";
      purpose = "host runtime closure, minus what the base already carries";
    }
  ];

  # mkfs.erofs writes the label into a 16-byte superblock field and rejects
  # anything that does not leave room for the NUL — measured: 15 accepted, 16
  # refused with "invalid volume label".  `nix-store-` already costs 10, hence
  # the 3-digit index: it fits, sorts lexically, and leaves 999 layers of room
  # (far past OVL_MAX_STACK = 500).
  labelLimit = 15;
  overlongLabels = builtins.filter (layer: builtins.stringLength layer.label > labelLimit) layers;

  # Layers are found by label, so two layers sharing one would be ambiguous.
  distinctLabels = builtins.attrNames (
    builtins.listToAttrs (
      map (layer: {
        name = layer.label;
        value = null;
      }) layers
    )
  );
in
assert
  overlongLabels == [ ]
  || throw (
    "erofs-store-layers: label longer than ${toString labelLimit} characters: "
    + builtins.concatStringsSep ", " (map (layer: layer.label) overlongLabels)
  );
assert
  builtins.length distinctLabels == builtins.length layers
  || throw "erofs-store-layers: duplicate layer label";
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
  # overlay `lowerdir` order.  The kernel documents the latter: "the specified
  # lower directories will be stacked beginning from the rightmost one and going
  # left", so the leftmost is the top layer and the newest has to go first there.
  inherit layers;
}
