# Packs a Nix store closure into a read-only EROFS image, on the HOST.
#
# Why this exists: materializing the closure as ~260k individual files inside
# the nested QEMU guest is what dominates the bringup image build (measured:
# ~11 ms/file, i.e. ~87 files/s vs thousands/s natively — the build is bound by
# per-file operations, not bytes).  `mkfs.erofs` needs no root, so packing the
# store here keeps this a pure derivation (cacheable, substitutable,
# fleet-dedupable) while turning those 260k creations into one sequential write.
#
# The image is mounted read-only as the lower layer of /nix/store; a writable
# overlay upper on ZFS carries anything written after bringup.
#
# Recipe mirrors nixpkgs `virtualisation.useNixStoreImage` (nixos/modules/
# virtualisation/qemu-vm.nix) so we inherit its determinism guarantees:
# --force-uid/gid=0 + -T 0 + fixed UUID => bit-identical output across hosts.
{
  pkgs,
  lib ? pkgs.lib,
  # Prebuilt `pkgs.closureInfo` derivation.  Taken as a whole rather than as
  # root paths so the image and the `nix-store --load-db` registration the
  # installer replays are guaranteed to describe the same closure.
  closureInfo,
  label ? "nix-store",
  # Fixed by design: a generated UUID would tag otherwise identical bytes with
  # a different store path and defeat cross-host dedup.
  uuid ? "9f4a1d2e-6c83-4b17-9e5a-2d7f0c8b3a61",
  # Uncompressed on purpose.  The scarce resource on the consuming side is CPU
  # (nested-KVM guests cap at 6 vCPUs), not bytes — host throughput is >1 GB/s.
  # A compressed lower would trade a one-shot sequential write for a permanent
  # decompression tax on every store read.  Only set this for bandwidth-bound
  # consumers (e.g. a store shipped to a roaming node over a hotspot).
  compression ? null,
  name ? "io.seedmatic.ndh-nix-store-erofs",
}:
pkgs.runCommand name
  {
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.erofs-utils
    ];
    passthru = { inherit label uuid closureInfo; };
  }
  ''
    # `--tar=f` streams a tar into mkfs.erofs, so the closure is never staged
    # on disk twice.  The transforms strip the /nix/store/ prefix (the image is
    # mounted *at* the store root) and undo Nix's case-hack suffixes, which
    # exist only to survive case-insensitive filesystems.
    tar --create \
      --absolute-names \
      --verbatim-files-from \
      --transform 'flags=rSh;s|/nix/store/||' \
      --transform 'flags=rSh;s|~nix~case~hack~[[:digit:]]\+||g' \
      --files-from ${closureInfo}/store-paths \
      | mkfs.erofs \
        --quiet \
        --force-uid=0 \
        --force-gid=0 \
        -L ${label} \
        -U ${uuid} \
        -T 0 \
        --hard-dereference \
        ${lib.optionalString (compression != null) "-z ${compression}"} \
        --tar=f \
        "$out"
  ''
