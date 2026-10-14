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
# layer set, and a mismatch — layers changed since the delivery — fails before mounting.
#
# The layers below the snapshot are the ones `deliver` stamped in `lower.layers` — nerd-nixos's
# frozen layers of that boot, then the EROFS ones — never the current ones: after a freeze-reboot
# the container comes back on its old snapshot while nerd-nixos already runs the new stack.
#
# Env: LAYER_CONTRACT (/etc/ndh/store-layers.json), CONTAINER_DIR, CONTAINER_NAME.

[ -s "$CONTAINER_DIR/lower.layers" ] ||
  { echo "ndh-incus-container-store: no stamped layer list — run: ndh-incus-container deliver $CONTAINER_NAME" >&2; exit 1; }
mapfile -t layers <"$CONTAINER_DIR/lower.layers"
mapfile -t required < <(yq -p json -oy -r '.requiredOptions[]' "$LAYER_CONTRACT")
# ZFS snapshots have a null filesystem UUID: over the delivery snapshot alone `index=on` holds, but
# with nerd-nixos's frozen layers below it the kernel drops it silently (measured 2026-10-14). Then
# the stamp below — the snapshot, and the layers' content and order — is the only guard, as the
# store-freeze spec states, and `index=on` is neither requested nor required.
mapfile -t erofs < <(yq -p json -oy -r '.lowerdirs[]' "$LAYER_CONTRACT")
if [ "${#layers[@]}" -gt "${#erofs[@]}" ]; then
  mapfile -t required < <(printf '%s\n' "${required[@]}" | grep -vx 'index=on' || true)
fi
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
for layer in "${layers[@]}"; do
  [ -d "$layer" ] || fail "layer $layer, stamped at delivery, is gone — run: ndh-incus-container deliver $CONTAINER_NAME"
done

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
    -o "lowerdir=$lowerdirs,upperdir=$CONTAINER_DIR/upper,workdir=$CONTAINER_DIR/work${requested:+,$requested}" "$store"
fi

options=",$(findmnt -no OPTIONS "$store"),"
[[ "$options" == *",lowerdir=$lowerdirs,"* ]] || fail "lowerdir is not the snapshot over the layer contract's ($lowerdirs) — effective options:${options}"
for option in "${required[@]}"; do
  [[ "$options" == *",$option,"* ]] || fail "$option did not hold — effective options:${options}"
done

[ -e "$stamp" ] || echo "$expected" >"$stamp"
