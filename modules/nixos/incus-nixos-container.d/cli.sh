# The operator's gestures on ndh's NixOS containers. Nothing here runs by itself: creating,
# delivering and switching change the live system.
#
#   ndh-incus-container list
#   ndh-incus-container create  {name}   dataset, store overlay, project, instance and its devices
#   ndh-incus-container deliver {name}   copy this generation's container system into its store
#   ndh-incus-container switch  {name}   activate the delivered system in the running container
#   ndh-incus-container reset   {name}   set a stopped container's store aside after its layers changed
#
# Set by the wrapper: INSTANCES (JSON), PROJECT, POOL, LOWER_CURRENT, GUEST_LOWER, GUEST_UPPER, NIX_CONFIG.

usage() {
  sed -n '4,8p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

instance() {
  NAME="$1" yq -p json -o json -I0 -e '.[strenv(NAME)]' <<<"$INSTANCES" 2>/dev/null ||
    { echo "ndh-incus-container: no instance '$1' is declared on this member" >&2; exit 1; }
}

field() { KEY="$2" yq -p json -oy -r '.[strenv(KEY)]' <<<"$1"; }

create() {
  local info dir dataset target placement=()
  info=$(instance "$1")
  dir=$(field "$info" dir)
  dataset=$(field "$info" dataset)
  target=$(yq -p json -oy -r '.target // ""' <<<"$info")

  if [ "$(incus query /1.0/cluster | yq -p json -oy -r '.enabled')" = true ]; then
    [ -n "$target" ] || { echo "ndh-incus-container: this member is clustered, and $1 states no target" >&2; exit 1; }
    placement=(--target "$target")
  elif [ -n "$target" ]; then
    echo "ndh-incus-container: this Incus is not clustered, so target $target cannot apply to $1" >&2
    exit 1
  fi

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
  # A new project's default profile has no root disk, and Incus refuses an instance without one.
  incus init --empty --project "$PROJECT" --storage "$POOL" "${placement[@]}" "$1" \
    -c security.privileged=true \
    -c cluster.evacuate=stop \
    -c boot.autostart=true \
    -c raw.lxc="lxc.init.cmd = /nix/var/nix/profiles/system/init"
  # From here a failure deletes the instance: a half-configured one would make the next `create`
  # stop at "already exists".
  created="$1"
  trap 'incus delete --force --project "$PROJECT" "$created"' ERR
  for mountpoint in proc sys dev run tmp; do
    incus file create --project "$PROJECT" --type=directory "$1/$mountpoint"
  done
  incus config device add --project "$PROJECT" "$1" nix disk \
    source="$dir/root/nix" path=/nix recursive=true
  # The lower view's store is a mount of its own, and the kernel refuses a recursive read-only bind:
  # its two halves go in as two plain read-only binds.
  incus config device add --project "$PROJECT" "$1" nix-lower-store disk \
    source="$LOWER_CURRENT/nix/store" path="$GUEST_LOWER/nix/store" readonly=true
  incus config device add --project "$PROJECT" "$1" nix-lower-db disk \
    source="$LOWER_CURRENT/nix/var/nix" path="$GUEST_LOWER/nix/var/nix" readonly=true
  incus config device add --project "$PROJECT" "$1" nix-upper disk \
    source="$dir/upper" path="$GUEST_UPPER"
  local device keys
  for device in $(yq -p json -oy -r '.devices | keys | .[]' <<<"$info"); do
    mapfile -t keys < <(DEVICE="$device" yq -p json -oy -r '.devices[strenv(DEVICE)] | to_entries | .[] | .key + "=" + .value' <<<"$info")
    incus config device add --project "$PROJECT" "$1" "$device" "${keys[@]}"
  done
  trap - ERR
  echo "ndh-incus-container: $1 created on ${target:-this standalone member} — deliver it, then: incus start --project $PROJECT $1"
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

# After a re-bringup of nerd-nixos the layers change, and an `index=on` upper is bound to the layer
# set it was first mounted on (ESTALE). The store unit then refuses to mount and names this gesture.
# Upper, work and the container's /nix/var/nix go to one dated `.reset-{ts}`, the previous one is
# deleted, and `deliver` re-populates the store. Service data lives on its own devices.
reset() {
  local info dir aside entry old
  info=$(instance "$1")
  dir=$(field "$info" dir)

  # A running container still holds the store overlay through its disk device, even once nerd-nixos
  # has unmounted its own view of it.
  if incus info --project "$PROJECT" "$1" >/dev/null 2>&1 &&
    [ "$(incus query "/1.0/instances/$1/state?project=$PROJECT" | yq -p json -oy -r '.status')" != Stopped ]; then
    echo "ndh-incus-container: $1 is not stopped — incus stop --project $PROJECT $1" >&2
    exit 1
  fi
  systemctl stop "ndh-incus-container-store-$1.service"
  if mountpoint -q "$dir/root/nix/store"; then
    echo "ndh-incus-container: $dir/root/nix/store is still mounted" >&2
    exit 1
  fi

  aside="$dir/.reset-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$aside/root/nix/var"
  for entry in upper work upper.layer-set; do
    if [ -e "$dir/$entry" ]; then mv "$dir/$entry" "$aside/"; fi
  done
  if [ -e "$dir/root/nix/var/nix" ]; then mv "$dir/root/nix/var/nix" "$aside/root/nix/var/"; fi
  for old in "$dir"/.reset-*; do
    if [ "$old" != "$aside" ]; then rm -rf --one-file-system "$old"; fi
  done

  systemctl start "ndh-incus-container-store-$1.service"
  echo "ndh-incus-container: $1 reset, the previous store is in $aside — deliver it, then: incus start --project $PROJECT $1"
}

case "${1:-}" in
  list) yq -p json -oy -r 'to_entries | .[] | .key + "  target=" + (.value.target // "standalone") + "  " + .value.toplevel' <<<"$INSTANCES" ;;
  create | deliver | switch | reset)
    [ -n "${2:-}" ] || usage
    "$1" "$2"
    ;;
  *) usage ;;
esac
