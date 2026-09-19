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
  # Path to nix-bash-trampoline.sh, which the pack script sources to get a known
  # bash plus the logger.  Threaded in rather than rebuilt here so every script
  # in the tree bootstraps through the same one.
  nixBashTrampoline,
  # Prebuilt `pkgs.closureInfo` derivation.  Taken as a whole rather than as
  # root paths so the image and the `nix-store --load-db` registration the
  # installer replays are guaranteed to describe the same closure.
  closureInfo,
  # Which store paths to pack, one per line.  Defaults to the whole closure; a
  # layer in a stack passes a subset instead (a generation's paths minus what the
  # layers below already carry).  The subset is NOT dependency-closed on its own
  # — only the stack is — which is why `closureInfo` stays a separate input: the
  # registration the installer replays must describe the union, not this layer.
  storePathsFile ? "${closureInfo}/store-paths",
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
let
  # Extracted rather than inlined: this repo materializes its shell as assets and
  # bootstraps them through the trampoline + logger, so the pack gets the same
  # treatment as mk-disk-image-with-manifest.sh — which is also a builder script.
  packScript = pkgs.replaceVars ./erofs-store-image.d/pack.sh {
    inherit nixBashTrampoline;
    loggerTag = "nixos.erofsStoreImage";
  };
in
pkgs.runCommand name
  {
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.erofs-utils
    ];
    passthru = { inherit label uuid closureInfo; };
  }
  ''
    ${pkgs.bash}/bin/bash ${packScript} \
      ${storePathsFile} \
      ${label} \
      ${uuid} \
      "$out" \
      ${lib.optionalString (compression != null) compression}
  ''
