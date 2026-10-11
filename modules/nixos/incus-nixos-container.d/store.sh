# One container's /nix/store: the EROFS layers FLAT as lowerdir, its dataset as upper. Fails hard,
# leaving nothing mounted, when the effective mount is not the layer contract's — a wrong lowerdir
# list, or an `index=on` the kernel silently dropped.
#
# Env: LAYER_CONTRACT (/etc/ndh/store-layers.json), CONTAINER_DIR.

mapfile -t layers < <(yq -p json -r '.lowerdirs[]' "$LAYER_CONTRACT")
mapfile -t required < <(yq -p json -r '.requiredOptions[]' "$LAYER_CONTRACT")
lowerdirs=$(IFS=:; echo "${layers[*]}")
requested=$(IFS=,; echo "${required[*]}")

store="$CONTAINER_DIR/root/nix/store"
mkdir -p "$CONTAINER_DIR/upper" "$CONTAINER_DIR/work" "$store" \
  "$CONTAINER_DIR/root/nix/var/nix" "$CONTAINER_DIR/root/nix/.lower" "$CONTAINER_DIR/root/nix/.upper"

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
