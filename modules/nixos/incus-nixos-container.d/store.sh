# One container's /nix/store: the EROFS layers FLAT as lowerdir, its dataset as upper. Fails hard,
# leaving nothing mounted, when the effective mount is not the layer contract's — a wrong lowerdir
# list, or an `index=on` the kernel silently dropped.
#
# An `index=on` upper is bound to the lower set it was first mounted on: over changed layers the
# kernel refuses it with ESTALE (measured 2026-10-11). The upper is stamped with the layer set's
# fingerprint, and a mismatch fails here, before mounting, naming the gesture that resets it.
#
# Env: LAYER_CONTRACT (/etc/ndh/store-layers.json), LOWER_CURRENT, CONTAINER_DIR, CONTAINER_NAME.

mapfile -t layers < <(yq -p json -oy -r '.lowerdirs[]' "$LAYER_CONTRACT")
mapfile -t required < <(yq -p json -oy -r '.requiredOptions[]' "$LAYER_CONTRACT")
lowerdirs=$(IFS=:; echo "${layers[*]}")
requested=$(IFS=,; echo "${required[*]}")
fingerprint=$(readlink "$LOWER_CURRENT")

store="$CONTAINER_DIR/root/nix/store"
stamp="$CONTAINER_DIR/upper.layer-set"
mkdir -p "$CONTAINER_DIR/upper" "$CONTAINER_DIR/work" "$store" \
  "$CONTAINER_DIR/root/nix/var/nix" "$CONTAINER_DIR/root/nix/.lower" "$CONTAINER_DIR/root/nix/.upper"

if [ -e "$stamp" ] && [ "$(cat "$stamp")" != "$fingerprint" ]; then
  echo "ndh-incus-container-store: the upper of $CONTAINER_NAME belongs to layer set $(cat "$stamp")," \
    "nerd-nixos booted $fingerprint — run: ndh-incus-container reset $CONTAINER_NAME" >&2
  exit 1
fi

if ! mountpoint -q "$store"; then
  mount -t overlay overlay \
    -o "lowerdir=$lowerdirs,upperdir=$CONTAINER_DIR/upper,workdir=$CONTAINER_DIR/work,$requested" "$store"
fi

options=",$(findmnt -no OPTIONS "$store"),"
fail() {
  echo "ndh-incus-container-store: $1 — effective options:${options}" >&2
  umount "$store"
  exit 1
}
[[ "$options" == *",lowerdir=$lowerdirs,"* ]] || fail "lowerdir is not the layer contract's ($lowerdirs)"
for option in "${required[@]}"; do
  [[ "$options" == *",$option,"* ]] || fail "$option did not hold"
done

[ -e "$stamp" ] || echo "$fingerprint" >"$stamp"
