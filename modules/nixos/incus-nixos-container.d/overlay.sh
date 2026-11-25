overlay:devices:list() {
  printf '%s %s\n' nix "$1/root/nix" nix-lower-store "$1/view/nix/store" nix-lower-db "$1/view/nix/var/nix" nix-upper "$1/upper"
}

overlay:unmount() {
  local m
  for m in "$1/root/nix/store" "$1/view/nix/store"; do
    if mountpoint -q "$m"; then umount "$m"; fi
  done
}

overlay:mount() {
  CONTAINER_DIR=$1 CONTAINER_NAME=$2 CONTAINER_PRIVILEGED=$3 LAYER_CONTRACT=$LAYER_CONTRACT "$BASH" "$STORE_SCRIPT"
}

overlay:point() {
  local config device src info
  info=$(incus:instance "${3:-$1}")
  config=$(incus config show --project "$PROJECT" "$1")
  # Pointed only when ALL FOUR sources are overlay:devices:list' and the hook names the dir: a half-pointed container (one
  # device right, another still on the old dir) is the very state a cut leaves, and must be rewritten (🛡️).
  local pointed=1
  while read -r device src; do
    actual=$(DEV="$device" yq -p yaml -oy -r '.devices[strenv(DEV)].source // ""' <<<"$config")
    [ "$actual" = "$src" ] || pointed=0
  done < <(overlay:devices:list "$2")
  rawLxc=$(yq -p yaml -oy -r '.config."raw.lxc" // ""' <<<"$config")
  [[ "$rawLxc" == *" $2" ]] || pointed=0
  [ "$pointed" = 0 ] || return 0
  while read -r device src; do
    config=$(DEV="$device" SRC="$src" yq '.devices[strenv(DEV)].source = strenv(SRC)' <<<"$config")
  done < <(overlay:devices:list "$2")
  config=$(RAW="$(util:raw_lxc:build "$2")" yq '.config."raw.lxc" = strenv(RAW)' <<<"$config")
  # Past the incus wrapper, which closes stdin: the edit reads the config there.
  command incus config edit --project "$PROJECT" "$1" <<<"$config"
}

