#!/usr/bin/env bash
# Packs a set of Nix store paths into one read-only EROFS layer.
#
# Runs as a nix builder, on the HOST: mkfs.erofs needs no root, so packing here
# keeps the layer a pure derivation (cacheable, substitutable, fleet-dedupable)
# instead of materializing ~260k individual files inside the nested guest, which
# is what dominated the bringup image build (~11 ms/file, i.e. ~87 files/s).
#
# shellcheck source=/dev/null
source "@nixBashTrampoline@"

main() {
  # `pipefail` is load-bearing here, not hygiene: mkfs.erofs happily writes a
  # VALID image from a tar stream that stopped early, so a `tar` killed mid-way
  # (a builder under memory pressure, a full disk) would otherwise ship a
  # silently incomplete layer that only fails much later, on a node that cannot
  # find a store path.
  set -euo pipefail
  set -x

  local store_paths_file="$1"
  local label="$2"
  local uuid="$3"
  local output="$4"
  local compression="${5:-}"

  # A layer with no paths is a declaration error, not a degenerate case: the
  # stack would carry a disk the guest must mount to boot and that holds
  # nothing.  Fail here rather than ship it.
  if [[ ! -s "$store_paths_file" ]]; then
    echo "[erofs-store-image][ERROR] no store paths to pack for label '${label}'" >&2
    exit 1
  fi

  # --force-uid/gid=0 + -T 0 + a fixed UUID are what make the output
  # bit-identical across hosts, which is what lets the fleet share one layer.
  local -a mkfs_opts=(
    --quiet
    --force-uid=0
    --force-gid=0
    -L "$label"
    -U "$uuid"
    -T 0
    --hard-dereference
  )

  if [[ -n "$compression" ]]; then
    mkfs_opts+=(-z "$compression")
  fi

  # `--tar=f` streams a tar into mkfs.erofs, so the closure is never staged on
  # disk twice.  The transforms strip the /nix/store/ prefix (the layer is
  # mounted *at* the store root) and undo Nix's case-hack suffixes, which exist
  # only to survive case-insensitive filesystems.
  tar --create \
    --absolute-names \
    --verbatim-files-from \
    --transform 'flags=rSh;s|/nix/store/||' \
    --transform 'flags=rSh;s|~nix~case~hack~[[:digit:]]\+||g' \
    --files-from "$store_paths_file" \
    | mkfs.erofs "${mkfs_opts[@]}" --tar=f "$output"
}

ndh::logger:command:run "@loggerTag@" main "$@"
