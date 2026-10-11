# The operator's gestures on ndh's NixOS containers. Nothing here runs by itself: creating,
# delivering and switching change the live system.
#
#   ndh-incus-container list
#   ndh-incus-container create  {name}   dataset, store overlay, project, instance and its devices
#   ndh-incus-container deliver {name}   copy this generation's container system into its store
#   ndh-incus-container switch  {name}   activate the delivered system in the running container
#
# Set by the wrapper: INSTANCES (JSON), PROJECT, LOWER_CURRENT, GUEST_LOWER, GUEST_UPPER, NIX_CONFIG.

usage() {
  sed -n '4,7p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

instance() {
  NAME="$1" yq -p json -o json -I0 -e '.[strenv(NAME)]' <<<"$INSTANCES" 2>/dev/null ||
    { echo "ndh-incus-container: no instance '$1' is declared on this member" >&2; exit 1; }
}

field() { KEY="$2" yq -p json -r '.[strenv(KEY)]' <<<"$1"; }

create() {
  local info dir dataset target
  info=$(instance "$1")
  dir=$(field "$info" dir)
  dataset=$(field "$info" dataset)
  target=$(field "$info" target)

  # Created here, not by disko: disko formats the pool at bringup and never revisits it.
  zfs list -H "$dataset" >/dev/null 2>&1 ||
    zfs create -p -o mountpoint="$dir" -o xattr=sa -o acltype=posixacl -o recordsize=16K "$dataset"
  systemctl start "ndh-incus-container-store-$1.service"

  incus project show "$PROJECT" >/dev/null 2>&1 || incus project create "$PROJECT"
  if incus info --project "$PROJECT" "$1" >/dev/null 2>&1; then
    echo "ndh-incus-container: $1 already exists in project $PROJECT"
    return
  fi

  # An empty rootfs: the system lives in /nix, and init is its profile. The rootfs keeps only the
  # mount points LXC needs.
  incus init --empty --project "$PROJECT" --target "$target" "$1" \
    -c security.privileged=true \
    -c cluster.evacuate=stop \
    -c boot.autostart=true \
    -c raw.lxc="lxc.init.cmd = /nix/var/nix/profiles/system/init"
  for mountpoint in proc sys dev run tmp; do
    incus file create --project "$PROJECT" --type=directory "$1/$mountpoint"
  done
  incus config device add --project "$PROJECT" "$1" nix disk \
    source="$dir/root/nix" path=/nix recursive=true
  incus config device add --project "$PROJECT" "$1" nix-lower disk \
    source="$LOWER_CURRENT" path="$GUEST_LOWER" readonly=true recursive=true
  incus config device add --project "$PROJECT" "$1" nix-upper disk \
    source="$dir/upper" path="$GUEST_UPPER"
  local device keys
  for device in $(yq -p json -r '.devices | keys | .[]' <<<"$info"); do
    mapfile -t keys < <(DEVICE="$device" yq -p json -r '.devices[strenv(DEVICE)] | to_entries | .[] | .key + "=" + .value' <<<"$info")
    incus config device add --project "$PROJECT" "$1" "$device" "${keys[@]}"
  done
  echo "ndh-incus-container: $1 created on $target — deliver it, then: incus start --project $PROJECT $1"
}

deliver() {
  local info dir toplevel store
  info=$(instance "$1")
  dir=$(field "$info" dir)
  toplevel=$(field "$info" toplevel)
  store=$(field "$info" hostStore)

  systemctl start "ndh-incus-container-store-$1.service"
  # Only the delta lands in the upper: nix reads the lower's DB, so what the layers hold is not copied.
  nix copy --to "$store" "$toplevel"
  nix-env --store "$store" -p "$dir/root/nix/var/nix/profiles/system" --set "$toplevel"
  echo "ndh-incus-container: $1 ← $toplevel"
}

switch() {
  instance "$1" >/dev/null
  incus exec --project "$PROJECT" "$1" -- /nix/var/nix/profiles/system/bin/switch-to-configuration switch
}

case "${1:-}" in
  list) yq -p json -r 'to_entries | .[] | .key + "  target=" + .value.target + "  " + .value.toplevel' <<<"$INSTANCES" ;;
  create | deliver | switch)
    [ -n "${2:-}" ] || usage
    "$1" "$2"
    ;;
  *) usage ;;
esac
