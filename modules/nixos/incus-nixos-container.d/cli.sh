# The operator's gestures on ndh's NixOS containers. Nothing here runs by itself: creating and
# delivering change the live system.
#
#   ndh-incus-container list
#   ndh-incus-container create  {name}   dataset, project, instance and its devices
#   ndh-incus-container deliver {name}   restart the container on a snapshot of this generation's store
#
# Set by the wrapper: INSTANCES (JSON), PROJECT, POOL, LAYER_CONTRACT, GUEST_LOWER, GUEST_UPPER,
# PRESTART_HOOK, STACK_DESCRIPTION, STORE_DEGRADED, GCROOTS, NIX_CONFIG.

usage() {
  sed -n '4,6p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

die() {
  echo "ndh-incus-container: $1" >&2
  exit 1
}

instance() {
  NAME="$1" yq -p json -o json -I0 -e '.[strenv(NAME)]' <<<"$INSTANCES" 2>/dev/null ||
    die "no instance '$1' is declared on this member"
}

field() { KEY="$2" yq -p json -oy -r '.[strenv(KEY)]' <<<"$1"; }

# raw_lxc {dir}: ONE key, so init and the pre-start hook share its value; a second `raw.lxc=` would
# replace the first and lose init.
raw_lxc() {
  printf 'lxc.init.cmd = /nix/var/nix/profiles/system/init\nlxc.hook.pre-start = %s %s\n' "$PRESTART_HOOK" "$1"
}

create() {
  local info dir dataset target placement=()
  info=$(instance "$1")
  dir=$(field "$info" dir)
  dataset=$(field "$info" dataset)
  target=$(yq -p json -oy -r '.target // ""' <<<"$info")

  if [ "$(incus query /1.0/cluster | yq -p json -oy -r '.enabled')" = true ]; then
    [ -n "$target" ] || die "this member is clustered, and $1 states no target"
    placement=(--target "$target")
  elif [ -n "$target" ]; then
    die "this Incus is not clustered, so target $target cannot apply to $1"
  fi

  # Created here, not by disko: disko formats the pool at bringup and never revisits it.
  zfs list -H "$dataset" >/dev/null 2>&1 ||
    zfs create -p -o mountpoint="$dir" -o xattr=sa -o acltype=posixacl -o recordsize=16K "$dataset"
  # Incus checks every disk device's source when it adds the device and when it starts the instance.
  mkdir -p "$dir/root/nix" "$dir/upper" "$dir/view/nix/store" "$dir/view/nix/var/nix"

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
    -c raw.lxc="$(raw_lxc "$dir")"
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
    source="$dir/view/nix/store" path="$GUEST_LOWER/nix/store" readonly=true
  incus config device add --project "$PROJECT" "$1" nix-lower-db disk \
    source="$dir/view/nix/var/nix" path="$GUEST_LOWER/nix/var/nix" readonly=true
  incus config device add --project "$PROJECT" "$1" nix-upper disk \
    source="$dir/upper" path="$GUEST_UPPER"
  local device type keys
  for device in $(yq -p json -oy -r '.devices | keys | .[]' <<<"$info"); do
    # Incus takes the type as a positional argument and refuses `type=` among the keys.
    type=$(DEVICE="$device" yq -p json -oy -r '.devices[strenv(DEVICE)].type' <<<"$info")
    mapfile -t keys < <(DEVICE="$device" yq -p json -oy -r '.devices[strenv(DEVICE)] | to_entries | .[] | select(.key != "type") | .key + "=" + .value' <<<"$info")
    incus config device add --project "$PROJECT" "$1" "$device" "$type" "${keys[@]}"
  done
  trap - ERR
  echo "ndh-incus-container: $1 created on ${target:-this standalone member} — deliver it"
}

# The container's lowers are a ZFS snapshot of nerd-nixos's own store, upper and DB taken in ONE
# command (atomic), on top of the EROFS layers. nerd-nixos built the container's system into that
# store when it switched, so the snapshot already carries it: the container's upper starts empty and
# only receives what the container itself writes. nerd-nixos's GC can no longer take a path from
# under a container, since the snapshot keeps it. Each delivery is a restart on a fresh upper, the
# way nerd-nixos itself takes a new generation; service data lives on its own devices.
#
# Once nerd-nixos freezes, its upper is nearly empty after each boot: the snapshot alone no longer
# holds the system, its frozen layers do. So the delivery STAMPS the layers it was taken over —
# nerd-nixos's frozen layers of this boot, then the EROFS ones — in `lower.layers`, and the store
# unit mounts that list, never the current one: after a freeze-reboot the container comes back on
# its old snapshot while /run already describes the new stack. Only a delivery moves it.
deliver() {
  local info dir toplevel store upper_root rw db snapshot previous aside entry old
  info=$(instance "$1")
  dir=$(field "$info" dir)
  toplevel=$(field "$info" toplevel)
  store=$(field "$info" hostStore)
  upper_root=$(yq -p json -oy -r '.upperRoot' "$LAYER_CONTRACT")

  [ ! -e "$STORE_DEGRADED" ] || die "nerd-nixos's store is degraded — repair it before delivering"
  incus info --project "$PROJECT" "$1" >/dev/null 2>&1 || die "$1 does not exist — create it first"
  [ -e "$toplevel" ] || die "$toplevel is not in nerd-nixos's store — switch nerd-nixos to this generation first"
  [ "$(findmnt -no FSTYPE "$upper_root")" = zfs ] || die "$upper_root is not a ZFS dataset"
  [ "$(findmnt -no FSTYPE /nix/var/nix/db)" = zfs ] || die "/nix/var/nix/db is not a ZFS dataset"
  rw=$(findmnt -no SOURCE "$upper_root")
  db=$(findmnt -no SOURCE /nix/var/nix/db)
  previous=""
  if [ -e "$dir/lower.snapshot" ]; then previous=$(cat "$dir/lower.snapshot"); fi

  if [ "$(incus query "/1.0/instances/$1/state?project=$PROJECT" | yq -p json -oy -r '.status')" != Stopped ]; then
    incus stop --project "$PROJECT" "$1"
  fi
  systemctl stop "ndh-incus-container-store-$1.service"
  for entry in "$dir/root/nix/store" "$dir/view/nix/store"; do
    if mountpoint -q "$entry"; then die "$entry is still mounted"; fi
  done

  snapshot="ndh-incus-$1-$(date -u +%Y%m%dT%H%M%SZ)"
  zfs snapshot "$rw@$snapshot" "$db@$snapshot"
  # Reached host-side first: a snapshot automounted from a private namespace is ENOENT there.
  [ -d "$upper_root/.zfs/snapshot/$snapshot/upper" ] || die "snapshot $snapshot has no upper"

  aside="$dir/.previous-$snapshot"
  mkdir -p "$aside/root/nix/var" "$aside/view/nix/var/nix"
  for entry in upper work upper.layer-set lower.snapshot lower.layers; do
    if [ -e "$dir/$entry" ]; then mv "$dir/$entry" "$aside/"; fi
  done
  if [ -e "$dir/root/nix/var/nix" ]; then mv "$dir/root/nix/var/nix" "$aside/root/nix/var/"; fi
  if [ -e "$dir/view/nix/var/nix/db" ]; then mv "$dir/view/nix/var/nix/db" "$aside/view/nix/var/nix/"; fi
  # A copy, WAL included, never the snapshot's own file: nix opens it normally, and SQLite's
  # `immutable` mode would ignore the WAL.
  cp -a "/nix/var/nix/db/.zfs/snapshot/$snapshot" "$dir/view/nix/var/nix/db"
  mkdir -p "$dir/upper"
  {
    if [ -s "$STACK_DESCRIPTION" ]; then yq -p json -oy -r '.frozen[]' "$STACK_DESCRIPTION"; fi
    yq -p json -oy -r '.lowerdirs[]' "$LAYER_CONTRACT"
  } >"$dir/lower.layers"
  echo "$snapshot" >"$dir/lower.snapshot"
  incus config set --project "$PROJECT" "$1" raw.lxc="$(raw_lxc "$dir")"
  systemctl start "ndh-incus-container-store-$1.service"

  # The snapshot carries the system, so this copies nothing; it stays as the check that it does.
  # The source is nerd-nixos's own store, which built or validated every path; most carry no
  # signature, so a checked copy would refuse the first path of any delta.
  nix copy --no-check-sigs --to "$store" "$toplevel"
  nix-env --store "$store" -p "$dir/root/nix/var/nix/profiles/system" --set "$toplevel"
  # nerd-nixos's GC, freeze and compaction keep what a container runs.
  mkdir -p "$GCROOTS"
  ln -sfn "$toplevel" "$GCROOTS/$1"
  incus start --project "$PROJECT" "$1"

  # The container runs on the new snapshot: the previous one, and what was set aside, can go.
  if [ -n "$previous" ]; then
    zfs destroy "$rw@$previous"
    zfs destroy "$db@$previous"
  fi
  for old in "$dir"/.previous-*; do rm -rf --one-file-system "$old"; done
  echo "ndh-incus-container: $1 ← $toplevel, on snapshot $snapshot"
}

case "${1:-}" in
  list) yq -p json -oy -r 'to_entries | .[] | .key + "  target=" + (.value.target // "standalone") + "  " + .value.toplevel' <<<"$INSTANCES" ;;
  create | deliver)
    [ -n "${2:-}" ] || usage
    "$1" "$2"
    ;;
  *) usage ;;
esac
