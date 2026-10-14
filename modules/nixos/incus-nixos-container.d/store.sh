# One container's store, built on the ZFS snapshot of nerd-nixos's own store that `deliver` took:
# the snapshot's upper on top of the EROFS layers, all flat. Two mounts:
#   * {dir}/view/nix/store, read-only, an empty `.links` shim first: what nix inside the container
#     opens as its lower store, beside {dir}/view/nix/var/nix/db, the snapshot's DB copied by
#     `deliver`. Never an overlayfs lower.
#   * {dir}/root/nix/store, the container's store: its dataset's upper, `index=on`.
# Fails hard, leaving nothing mounted, when the effective mount is not the expected one — a wrong
# lowerdir list, or an `index=on` the kernel silently dropped.
#
# An `index=on` upper is bound to its lower set, but the kernel does NOT notice a newer snapshot of
# the same dataset (measured 2026-10-14). So the stamp beside the upper names the snapshot and the
# layer set, and a mismatch — layers appended since the delivery — fails before mounting.
#
# Env: LAYER_CONTRACT (/etc/ndh/store-layers.json), CONTAINER_DIR, CONTAINER_NAME.

mapfile -t layers < <(yq -p json -oy -r '.lowerdirs[]' "$LAYER_CONTRACT")
mapfile -t required < <(yq -p json -oy -r '.requiredOptions[]' "$LAYER_CONTRACT")
upper_root=$(yq -p json -oy -r '.upperRoot' "$LAYER_CONTRACT")
snapshot=$(cat "$CONTAINER_DIR/lower.snapshot")
frozen="$upper_root/.zfs/snapshot/$snapshot/upper"

store="$CONTAINER_DIR/root/nix/store"
view="$CONTAINER_DIR/view"
shim="$CONTAINER_DIR/.links-shim"
stamp="$CONTAINER_DIR/upper.layer-set"

fail() {
  echo "ndh-incus-container-store: $1" >&2
  for mounted in "$store" "$view/nix/store"; do
    if mountpoint -q "$mounted"; then umount "$mounted"; fi
  done
  exit 1
}

# Reached here, in the host's mount namespace: a snapshot automounted from a private namespace is
# ENOENT there (measured 2026-10-14).
[ -d "$frozen" ] || fail "snapshot $snapshot of nerd-nixos's store is gone — run: ndh-incus-container deliver $CONTAINER_NAME"
[ -e "$view/nix/var/nix/db/db.sqlite" ] || fail "no DB in $view — run: ndh-incus-container deliver $CONTAINER_NAME"

lowerdirs=$(IFS=:; echo "$frozen:${layers[*]}")
requested=$(IFS=,; echo "${required[*]}")
layer_set=$({
  echo "${layers[*]}"
  find "${layers[@]}" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%H/%f\n' | sort
} | sha256sum | cut -c1-16)
expected="$snapshot $layer_set"

if [ -e "$stamp" ] && [ "$(cat "$stamp")" != "$expected" ]; then
  fail "the upper of $CONTAINER_NAME belongs to ($(cat "$stamp")), nerd-nixos booted ($expected) — run: ndh-incus-container deliver $CONTAINER_NAME"
fi

mkdir -p "$shim/.links" "$view/nix/store" "$CONTAINER_DIR/upper" "$CONTAINER_DIR/work" "$store" \
  "$CONTAINER_DIR/root/nix/var/nix" "$CONTAINER_DIR/root/nix/.lower" "$CONTAINER_DIR/root/nix/.upper"

if ! mountpoint -q "$view/nix/store"; then
  # The shim's empty `.links`: nix 2.34 creates it even in a read-only store
  # (src/libstore/local-store.cc:139), and neither the layers nor the snapshot carry one.
  mount -t overlay overlay -o "ro,lowerdir=$shim:$lowerdirs" "$view/nix/store"
fi

if ! mountpoint -q "$store"; then
  mount -t overlay overlay \
    -o "lowerdir=$lowerdirs,upperdir=$CONTAINER_DIR/upper,workdir=$CONTAINER_DIR/work,$requested" "$store"
fi

options=",$(findmnt -no OPTIONS "$store"),"
[[ "$options" == *",lowerdir=$lowerdirs,"* ]] || fail "lowerdir is not the snapshot over the layer contract's ($lowerdirs) — effective options:${options}"
for option in "${required[@]}"; do
  [[ "$options" == *",$option,"* ]] || fail "$option did not hold — effective options:${options}"
done

[ -e "$stamp" ] || echo "$expected" >"$stamp"
