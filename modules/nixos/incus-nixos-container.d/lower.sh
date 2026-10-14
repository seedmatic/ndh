# The read-only metadata view of the layer set nerd-nixos booted, with a nix DB of its own: what nix
# inside each container opens as its lower store. Never an overlayfs lower — see
# incus-nixos-container.nix.
#
# Env: LAYER_CONTRACT (/etc/ndh/store-layers.json), LOWER_ROOT.

mapfile -t layers < <(yq -p json -oy -r '.lowerdirs[]' "$LAYER_CONTRACT")
lowerdirs=$(IFS=:; echo "${layers[*]}")

# One view per layer set, named by what each layer holds and by their order. The DB needs only the
# union, but an `index=on` upper is bound to the layers AND their order, and every container's upper
# is stamped with this same fingerprint (store.sh).
fingerprint=$({
  echo "$lowerdirs"
  find "${layers[@]}" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%H/%f\n' | sort
} | sha256sum | cut -c1-16)
view="$LOWER_ROOT/$fingerprint"
shim="$LOWER_ROOT/.links-shim"

mkdir -p "$shim/.links" "$view/nix/store" "$view/nix/var/nix"
if ! mountpoint -q "$view/nix/store"; then
  # The shim's empty `.links`: nix 2.34 creates it even in a read-only store
  # (src/libstore/local-store.cc:139), and the EROFS layers carry none.
  mount -t overlay overlay -o "ro,lowerdir=$shim:$lowerdirs" "$view/nix/store"
fi

if [ ! -e "$view/nix/var/nix/db/db.sqlite" ]; then
  # From nerd-nixos's own DB, which registered every layer path at install. Not shipped with the
  # layers: the running generation cannot name the layers' union closure, which holds its own
  # toplevel (bringup-zfs-disk-image.nix, `unionClosureInfo`).
  scratch=$(mktemp -d "$LOWER_ROOT/.db.XXXXXX")
  paths=()
  for entry in "$view"/nix/store/*; do paths+=("/nix/store/${entry##*/}"); done
  nix-store --dump-db "${paths[@]}" | nix-store --load-db --store "local?root=$scratch"
  mv "$scratch/nix/var/nix/db" "$view/nix/var/nix/db"
  rm -rf --one-file-system "$scratch"
  echo "ndh-incus-container-lower: DB for layer set $fingerprint, ${#paths[@]} paths"
fi

ln -sfn "$fingerprint" "$LOWER_ROOT/current"

# A previous layer set's view: the layers are fixed for a boot, so nothing can still use it.
for old in "$LOWER_ROOT"/*; do
  if [ ! -d "$old" ] || [ -L "$old" ] || [ "${old##*/}" = "$fingerprint" ]; then continue; fi
  if mountpoint -q "$old/nix/store"; then umount "$old/nix/store"; fi
  rm -rf --one-file-system "$old"
done
