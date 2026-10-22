#!/usr/bin/env bash
# ndh's NixOS containers. `create` is the operator's gesture; `converge` runs by itself after every
# switch and boot (ndh-incus-container-converge.service), and is the only thing that moves a container
# to a new system: the hand verbs below stay for the probe and for repairs.
#
#   ndh-incus-container list
#   ndh-incus-container create   {name}   dataset, project, instance and its devices
#   ndh-incus-container deliver  {name}   restart the container on a snapshot of this generation's store
#   ndh-incus-container converge          deliver every declared container whose system differs, keep it if
#                                         healthy, restore the previous system if not
#
# Under ndh's trampoline, no PATH of its own: incus, zfs, nix and systemctl are the guest system's, matched to its kernel
# module and daemons; the rest comes from the bringup runtime profile. The guest's activation installs that profile
# before any unit runs, and the trampoline refuses loudly where it is missing.
set -euo pipefail

# shellcheck disable=SC1091
source @nixBashTrampoline@

INSTANCES=@instances@
PROJECT=@project@
POOL=@pool@
LAYER_CONTRACT=@layerContract@
GUEST_LOWER=@guestLower@
GUEST_UPPER=@guestUpper@
PRESTART_HOOK=@prestartHook@
STACK_DESCRIPTION=@stackDescription@
STORE_DEGRADED=@storeDegraded@
GCROOTS=@gcroots@
HEALTH_TIMEOUT=@healthTimeout@
GUEST_SYSTEMCTL=@guestSystemctl@
NIX_CONFIG=@nixConfig@
export NIX_CONFIG

usage() {
  sed -n '/^#   ndh-incus-container /p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

# Every incus call, its stdin closed: run over `ssh host sudo …` stdin is an open pipe, and `incus project
# create` or `incus init` then wait there for a YAML configuration (measured live on bioskop-nixos,
# 2026-10-18). One wrapper, so a call added later cannot forget it.
incus() { command incus "$@" </dev/null; }

die() {
  echo "ndh-incus-container: $1" >&2
  exit 1
}

# instance {name}: the declared instance, as JSON. The name goes into paths, unit names and patterns: an
# Incus instance name's shape only, checked before anything uses it.
instance() {
  [[ $1 =~ ^[a-z][a-z0-9-]{0,62}$ ]] || die "'$1' is not an instance name"
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
  local info dir dataset target privileged placement=() shift=()
  info=$(instance "$1")
  dir=$(field "$info" dir)
  dataset=$(field "$info" dataset)
  target=$(yq -p json -oy -r '.target // ""' <<<"$info")
  privileged=$(field "$info" privileged)
  # Unprivileged: the container's ids are mapped above the host's, so its declared disks are shifted
  # back. The store's four cannot be: an overlay below a recursive bind and the EROFS view refuse an
  # idmapped mount (measured on the probe, 2026-10-16). The container then sees its store as
  # `nobody`'s — readable, never writable, which it never needs.
  [ "$privileged" = true ] || shift=(shift=true)

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
    -c security.privileged="$privileged" \
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
    [ "$type" != disk ] || keys+=("${shift[@]}")
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
# root_own {dir} {relative path}: every component of the path that exists is a directory of root's,
# not a symlink. deliver runs as host root inside a tree the container has run in, and `mkdir -p`
# follows symlinks: a component the container could replace would steer where root creates.
root_own() {
  local p="$1" c rel
  IFS=/ read -ra rel <<<"$2"
  for c in "" "${rel[@]}"; do
    p="$p${c:+/$c}"
    if [ -e "$p" ] || [ -L "$p" ]; then
      [ -d "$p" ] && [ ! -L "$p" ] && [ "$(stat -c %u "$p")" = 0 ] ||
        die "$p is not root's own directory — nothing delivered, and the container stays STOPPED"
    fi
  done
}

# declared_profiles {info}: "<path in the container>\t<package>" for every profile the instance declares, its
# system's first. What converge requires TRUE of a container, and what a delivery sets.
declared_profiles() {
  local profiles
  profiles=$(yq -p json -oy -r '(.profiles // {}) | to_entries | .[] | .key + "\t" + .value' <<<"$1") || return 1
  printf '/nix/var/nix/profiles/system\t%s\n%s\n' "$(field "$1" toplevel)" "$profiles"
}

# declared_ok {name}: every declared profile resolves to its package, each one that does not named on stdout.
# The one postcondition: converge's "up to date" and the end of a delivery. Called under `if`, errexit off,
# so every status is returned by hand.
declared_ok() {
  local info dir profiles profile package ok=0
  info=$(instance "$1") || return 1
  dir=$(field "$info" dir) || return 1
  profiles=$(declared_profiles "$info") || return 1
  while IFS=$'\t' read -r profile package; do
    [ -n "$profile" ] || continue
    if [ "$(readlink -f "$dir/root$profile" 2>/dev/null || true)" != "$(readlink -f "$package")" ]; then
      echo "$profile is not $package"
      ok=1
    fi
  done <<<"$profiles"
  return "$ok"
}

# deliver_keep {name}: the delivery up to the container's start, the previous state kept aside in
# `.previous-<snapshot>` (its upper, DB, lowers stamps and profiles) and its snapshot kept, so
# `rollback` can put it back exactly. Prints ONLY the new snapshot's name on stdout: what the steps
# print goes to stderr, since the caller captures stdout.
#
# The steps run in a process of their own: called under `||` or `if !`, as every caller here does, a
# function runs with errexit OFF for its whole body, and neither `set -e` again nor inherit_errexit
# turns it back on (measured, bash 5). A failed nix-env then went unseen and the delivery "succeeded"
# with a declared profile missing (🎛️, live on bioskop-nixos, 2026-10-22). A new process honours it.
deliver_keep() {
  local snapshot
  # Through the running interpreter, a store path: the trampoline keeps no `bash` of the caller's on PATH. The
  # snapshot comes back on fd 9: the logger holds fd 3.
  snapshot=$("$BASH" "${BASH_SOURCE[0]}" _deliver-steps "$1" 9>&1 1>&2) || return 1
  [ -n "$snapshot" ] || return 1
  echo "$snapshot"
}

deliver_steps() {
  local info dir toplevel store upper_root rw db snapshot aside entry runtime
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

  if [ "$(incus query "/1.0/instances/$1/state?project=$PROJECT" | yq -p json -oy -r '.status')" != Stopped ]; then
    incus stop --project "$PROJECT" "$1"
  fi
  # Stopped first, so nothing in the container changes a component between this check and the mkdir.
  for entry in "${GUEST_LOWER#/}/nix/store" "${GUEST_LOWER#/}/nix/var/nix" "${GUEST_UPPER#/}"; do
    root_own "$dir/root" "$entry"
  done
  # Before anything is snapshotted or moved: Incus can refuse it (an ETag race while it starts up,
  # measured), and a delivery that stops here has changed nothing.
  incus config set --project "$PROJECT" "$1" raw.lxc="$(raw_lxc "$dir")" ||
    die "Incus refused raw.lxc for $1 — nothing delivered, and the container stays STOPPED: run deliver again"
  systemctl stop "ndh-incus-container-store-$1.service"
  for entry in "$dir/root/nix/store" "$dir/view/nix/store"; do
    if mountpoint -q "$entry"; then die "$entry is still mounted"; fi
  done

  snapshot="ndh-incus-$1-$(date -u +%Y%m%dT%H%M%SZ)"
  zfs snapshot "$rw@$snapshot" "$db@$snapshot"
  # The service's data, at every delivery and with the container stopped, so the snapshot is consistent:
  # a ZFS snapshot costs nothing, and whether the new system migrates its data is not knowable here.
  local state
  for state in $(yq -p json -oy -r '(.stateDatasets // []) | .[]' <<<"$info"); do
    zfs snapshot -r "${state:?}@$snapshot"
  done
  # Reached host-side first: a snapshot automounted from a private namespace is ENOENT there.
  [ -d "$upper_root/.zfs/snapshot/$snapshot/upper" ] || die "snapshot $snapshot has no upper"

  aside="$dir/.previous-$snapshot"
  mkdir -p "$aside/root/nix/var" "$aside/view/nix/var/nix"
  for entry in upper work upper.layer-set lower.snapshot lower.layers lower.frozen; do
    if [ -e "$dir/$entry" ]; then mv "$dir/$entry" "$aside/"; fi
  done
  if [ -e "$dir/root/nix/var/nix" ]; then mv "$dir/root/nix/var/nix" "$aside/root/nix/var/"; fi
  if [ -e "$dir/view/nix/var/nix/db" ]; then mv "$dir/view/nix/var/nix/db" "$aside/view/nix/var/nix/"; fi
  # A copy, WAL included, never the snapshot's own file: nix opens it normally, and SQLite's
  # `immutable` mode would ignore the WAL.
  cp -a "/nix/var/nix/db/.zfs/snapshot/$snapshot" "$dir/view/nix/var/nix/db"
  mkdir -p "$dir/upper"
  # The store devices' mount points, host side: LXC makes a missing one at start, as the container's
  # root, and an unprivileged container's root cannot write in this root-owned tree (EPERM, measured
  # live on bioskop-nixos, 2026-10-18).
  mkdir -p "$dir/root$GUEST_LOWER/nix/store" "$dir/root$GUEST_LOWER/nix/var/nix" "$dir/root$GUEST_UPPER"
  local frozen_layers=""
  if [ -s "$STACK_DESCRIPTION" ]; then frozen_layers=$(yq -p json -oy -r '.frozen[]' "$STACK_DESCRIPTION"); fi
  {
    if [ -n "$frozen_layers" ]; then echo "$frozen_layers"; fi
    yq -p json -oy -r '.lowerdirs[]' "$LAYER_CONTRACT"
  } >"$dir/lower.layers"
  # Counted here, at delivery: a later change of the contract's EROFS list must not change it.
  if [ -n "$frozen_layers" ]; then wc -l <<<"$frozen_layers"; else echo 0; fi >"$dir/lower.frozen"
  echo "$snapshot" >"$dir/lower.snapshot"
  systemctl start "ndh-incus-container-store-$1.service"

  # The system's profile, then every other one the instance declares, all host side: the container's root
  # cannot write in the host-owned /nix bind when it is idmapped (EPERM, silently, from the container's
  # activation: measured by 🎛️ on bioskop-nixos, 2026-10-22, for the bringup runtime profile).
  # The list first, its status checked: a `while … < <(yq …)` loses yq's. Each profile's parent is made
  # here, root's own: nix-env makes none, and the old /nix/var/nix, its per-user/root included, went aside.
  # The snapshot carries each package, so `nix copy` copies nothing; it stays as the check that it does.
  # The source is nerd-nixos's own store, which built or validated every path; most carry no
  # signature, so a checked copy would refuse the first path of any delta.
  local profiles profile parent
  profiles=$(declared_profiles "$info")
  while IFS=$'\t' read -r profile runtime; do
    [ -n "$profile" ] || continue
    parent=$(dirname "${profile#/}")
    root_own "$dir/root" "$parent"
    # 0755 at every level it makes, whatever the caller's umask; `-m` would apply to the deepest one only.
    (umask 022 && mkdir -p "$dir/root/$parent")
    nix copy --no-check-sigs --to "$store" "$runtime"
    nix-env --store "$store" -p "$dir/root$profile" --set "$runtime"
  done <<<"$profiles"
  # Read on what landed, by converge's own test.
  declared_ok "$1" >&2 || die "$1 does not hold its declared profiles after delivery"
  # nerd-nixos's GC, freeze and compaction keep what a container runs.
  mkdir -p "$GCROOTS"
  ln -sfn "$toplevel" "$GCROOTS/$1"
  incus start --project "$PROJECT" "$1"
  echo "$snapshot" >&9
}

# snapshot_destroy [-r] {dataset@snapshot}: unmount what the kernel automounted of it under .zfs/snapshot, then destroy
# it. A snapshot read through .zfs/snapshot (deliver's upper and DB, the store's lowers) stays mounted until it
# expires, and ZFS refuses to destroy it meanwhile: "dataset is busy" (live on bioskop-nixos, 2026-10-22). A bounded
# retry backs it up, for a mount taken again between the umount and the destroy.
snapshot_destroy() {
  local recursive=() target name attempt
  if [ "$1" = -r ]; then recursive=(-r); shift; fi
  name=${1#*@}
  for attempt in 1 2 3 4 5; do
    while read -r target; do
      [ -n "$target" ] || continue
      umount "$target" || true
    done < <(findmnt -rn -o TARGET | grep -E "/\.zfs/snapshot/${name//./\\.}(/|\$)" || true)
    if zfs destroy "${recursive[@]}" "$1"; then return 0; fi
    [ "$attempt" = 5 ] || sleep 2
  done
  echo "ndh-incus-container: $1 is still busy after 5 attempts" >&2
  return 1
}

# state_snapshots {info} {name}: every delivery snapshot on the instance's state datasets.
state_snapshots() {
  local state
  for state in $(yq -p json -oy -r '(.stateDatasets // []) | .[]' <<<"$1"); do
    zfs list -H -t snapshot -o name "${state:?}" | grep -E "@ndh-incus-$2-[0-9]{8}T[0-9]{6}Z\$" || true
  done
}

# delivery_snapshot {name} {snapshot}: refuses anything but a delivery snapshot of this instance, in the one shape a
# delivery makes. Every entry point that takes one (_rollback, _commit) checks it before any path, destroy or pattern
# is built from it; matched afterwards as a fixed string, never as a pattern (🛡️: a `.*` kept nothing).
delivery_snapshot() {
  [[ $2 =~ ^ndh-incus-$1-[0-9]{8}T[0-9]{6}Z$ ]] || die "'$2' is not a delivery snapshot of $1"
}

# leftovers {name}: what a delivery leaves until its commit, one per line: every delivery snapshot of the instance but
# the one its store runs on (lower.snapshot), every state snapshot, every `.previous-*`. Empty once committed.
leftovers() {
  local info dir upper_root rw db current
  info=$(instance "$1") || return 1
  dir=$(field "$info" dir) || return 1
  upper_root=$(yq -p json -oy -r '.upperRoot' "$LAYER_CONTRACT") || return 1
  rw=$(findmnt -no SOURCE "$upper_root") || return 1
  db=$(findmnt -no SOURCE /nix/var/nix/db) || return 1
  current=$(cat "$dir/lower.snapshot") || return 1
  delivery_snapshot "$1" "$current"
  zfs list -H -t snapshot -o name "$rw" "$db" | grep -E "@ndh-incus-$1-[0-9]{8}T[0-9]{6}Z\$" |
    grep -vxF -e "$rw@$current" -e "$db@$current" || true
  state_snapshots "$info" "$1"
  local aside
  for aside in "$dir"/.previous-*; do [ ! -e "$aside" ] || echo "$aside"; done
}

# commit {name} {snapshot}: the container runs on {snapshot} and is kept; every other delivery snapshot
# of it (the previous one, and any a failed delivery left) and what was set aside can go. Its state
# snapshots all go, this delivery's included: they were only the way back. Resumable: run again after a failure,
# it destroys what is left and nothing else. In its own process, as rollback: converge runs it under `if`.
commit() { "$BASH" "${BASH_SOURCE[0]}" _commit "$1" "$2"; }

commit_steps() {
  local info dir upper_root rw db old
  delivery_snapshot "$1" "$2"
  info=$(instance "$1")
  dir=$(field "$info" dir)
  upper_root=$(yq -p json -oy -r '.upperRoot' "$LAYER_CONTRACT")
  rw=$(findmnt -no SOURCE "$upper_root")
  db=$(findmnt -no SOURCE /nix/var/nix/db)
  for old in $(zfs list -H -t snapshot -o name "$rw" "$db" | grep -E "@ndh-incus-$1-[0-9]{8}T[0-9]{6}Z\$" |
    grep -vxF -e "$rw@$2" -e "$db@$2" || true); do
    snapshot_destroy "$old"
  done
  for old in $(state_snapshots "$info" "$1"); do snapshot_destroy -r "$old"; done
  for old in "$dir"/.previous-*; do rm -rf --one-file-system "$old"; done
}

# rollback {name} {snapshot}: put back what `.previous-{snapshot}` kept, so the container restarts on
# its previous system, upper, DB, lowers and profiles byte for byte, and its state datasets as they
# were when it stopped; then {snapshot} goes. What the service wrote to its data meanwhile is lost: it
# is the price of bringing a forward data migration back.
#
# In its own process, as deliver_keep's steps: its callers run it under `if` and `||`, errexit off.
rollback() { "$BASH" "${BASH_SOURCE[0]}" _rollback "$1" "$2"; }

rollback_steps() {
  local info dir toplevel upper_root rw db aside entry previous state fs
  info=$(instance "$1")
  dir=$(field "$info" dir)
  toplevel=$(field "$info" toplevel)
  upper_root=$(yq -p json -oy -r '.upperRoot' "$LAYER_CONTRACT")
  rw=$(findmnt -no SOURCE "$upper_root")
  db=$(findmnt -no SOURCE /nix/var/nix/db)
  # The snapshot names a path and the datasets rolled back and destroyed: checked before any of them is touched.
  delivery_snapshot "$1" "$2"
  aside="$dir/.previous-$2"
  [ -d "$aside" ] || die "nothing kept for $1 at $aside — no rollback possible"

  incus stop --force --project "$PROJECT" "$1" || true
  systemctl stop "ndh-incus-container-store-$1.service"
  for entry in upper work upper.layer-set lower.snapshot lower.layers lower.frozen; do
    rm -rf --one-file-system "${dir:?}/$entry"
    if [ -e "$aside/$entry" ]; then mv "$aside/$entry" "$dir/"; fi
  done
  rm -rf --one-file-system "$dir/root/nix/var/nix" "$dir/view/nix/var/nix/db"
  if [ -e "$aside/root/nix/var/nix" ]; then mv "$aside/root/nix/var/nix" "$dir/root/nix/var/"; fi
  if [ -e "$aside/view/nix/var/nix/db" ]; then mv "$aside/view/nix/var/nix/db" "$dir/view/nix/var/nix/"; fi
  rm -rf --one-file-system "$aside"
  # The data as it was when the container stopped for this delivery: `zfs rollback` is per filesystem,
  # so every one under the declared dataset, each to its own snapshot of the recursive pair.
  for state in $(yq -p json -oy -r '(.stateDatasets // []) | .[]' <<<"$info"); do
    for fs in $(zfs list -H -o name -r -t filesystem "${state:?}"); do
      zfs rollback -r "$fs@$2"
    done
    snapshot_destroy -r "$state@$2"
  done
  snapshot_destroy "$rw@$2"
  snapshot_destroy "$db@$2"
  previous=$(cat "$dir/lower.snapshot" 2>/dev/null || true)
  [ -n "$previous" ] || die "$1 had no delivery before $2: it stays STOPPED"
  systemctl start "ndh-incus-container-store-$1.service"
  # The GC root follows what runs again: the previous system is the profile's target.
  mkdir -p "$GCROOTS"
  ln -sfn "$(readlink -f "$dir/root/nix/var/nix/profiles/system")" "$GCROOTS/$1"
  incus start --project "$PROJECT" "$1"
  echo "ndh-incus-container: $1 rolled back from $toplevel to snapshot $previous"
}

deliver() {
  local snapshot
  snapshot=$(deliver_keep "$1")
  commit "$1" "$snapshot"
  echo "ndh-incus-container: $1 ← $(field "$(instance "$1")" toplevel), on snapshot $snapshot"
}

# healthy {name}: RUNNING, then each declared health unit active within HEALTH_TIMEOUT seconds; a unit
# declared `conditional` is also healthy when systemd skipped it on its condition (ConditionResult=no),
# so a service waiting for material that is not there yet (nginx before its TLS leaf) is not a failure.
healthy() {
  local info deadline units unit kind state result
  info=$(instance "$1")
  deadline=$(($(date +%s) + HEALTH_TIMEOUT))
  until [ "$(incus query "/1.0/instances/$1/state?project=$PROJECT" | yq -p json -oy -r '.status')" = Running ]; do
    [ "$(date +%s)" -lt "$deadline" ] || {
      echo "ndh-incus-container: $1 is not RUNNING after ${HEALTH_TIMEOUT}s" >&2
      return 1
    }
    sleep 2
  done
  # Until the container's activation has made /run/current-system, its systemctl does not exist and Incus answers
  # "Error: Command not found" (live, 2026-10-22). That answer is the one expected here, so it is waited out, quietly
  # and within the same deadline, before any unit is probed.
  until incus exec --project "$PROJECT" "$1" -- "$GUEST_SYSTEMCTL" --version >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || {
      echo "ndh-incus-container: $1 has no $GUEST_SYSTEMCTL after ${HEALTH_TIMEOUT}s: its activation did not run" >&2
      return 1
    }
    sleep 2
  done
  # The list first, its status checked: `healthy` runs under `if`, errexit off, and an empty list read
  # from a failed yq would pass every container.
  units=$(yq -p json -oy -r '(.health.units // []) | .[] | .unit + "\t" + (.kind // "active")' <<<"$info") ||
    return 1
  while IFS=$'\t' read -r unit kind; do
    [ -n "$unit" ] || continue
    # By its path: the container's PATH is its activation's, and its system's systemctl is the one meant.
    until state=$(incus exec --project "$PROJECT" "$1" -- "$GUEST_SYSTEMCTL" is-active "$unit" || true) && [ "$state" = active ]; do
      if [ "$kind" = conditional ]; then
        result=$(incus exec --project "$PROJECT" "$1" -- "$GUEST_SYSTEMCTL" show -p ConditionResult --value "$unit" || true)
        [ "$result" != no ] || break
      fi
      [ "$state" != failed ] && [ "$(date +%s)" -lt "$deadline" ] || {
        echo "ndh-incus-container: $1's $unit is ${state:-unknown}, not active" >&2
        return 1
      }
      sleep 2
    done
  done <<<"$units"
}

# converge: every declared container whose system profile is not its declared toplevel is delivered,
# then kept if healthy, rolled back if not. One attempt per toplevel: a rolled-back one is marked in
# its dir, so a boot does not loop on the same bad system; the next guest generation retries. A container
# not yet created is the operator's (`create`), and is skipped, loudly. The exit status is 1 if any
# container could not be converged, so the unit fails visibly.
converge() {
  local name info dir toplevel declared wrong rest snapshot aside failed=0
  for name in $(yq -p json -oy -r 'keys | .[]' <<<"$INSTANCES"); do
    info=$(instance "$name")
    dir=$(field "$info" dir)
    toplevel=$(field "$info" toplevel)
    if ! incus info --project "$PROJECT" "$name" >/dev/null 2>&1; then
      echo "ndh-incus-container: $name is declared but not created: run ndh-incus-container create $name" >&2
      failed=1
      continue
    fi
    # Every declared profile, the system's and the others, resolved on both sides (a profile is a chain of
    # links: system → system-N-link → the store path). One that is not means a delivery: the container's scripts
    # read those profiles, so one set under a running container would go unchecked by any health test.
    if wrong=$(declared_ok "$name"); then
      # A commit that stopped half-way (a snapshot busy, live 2026-10-22) left the previous delivery behind; this
      # run finishes it, once the container proves healthy on what it runs: before that, the aside is its way back.
      local unfinished=0
      if ! rest=$(leftovers "$name"); then
        echo "ndh-incus-container: $name's leftovers could not be listed" >&2
        unfinished=1
      elif [ -n "$rest" ]; then
        if ! healthy "$name"; then
          echo "ndh-incus-container: $name holds its declared state but is unhealthy: its previous delivery is kept" >&2
          unfinished=1
        elif ! commit "$name" "$(cat "$dir/lower.snapshot")"; then
          echo "ndh-incus-container: $name's commit is still unfinished; the next converge resumes it" >&2
          unfinished=1
        else
          echo "ndh-incus-container: $name's previous delivery committed: ${rest//$'\n'/; }"
        fi
      fi
      # What holds needs no attempt marker: a stale one (a commit that died after a healthy delivery) goes.
      if [ "$unfinished" = 1 ]; then failed=1; else rm -f "$dir/converge.failed"; fi
      echo "ndh-incus-container: $name holds its declared system and profiles"
      continue
    fi
    echo "ndh-incus-container: $name to deliver: ${wrong//$'\n'/; }" >&2
    # One attempt per declared state and per delivering tool: a changed profile alone is a new attempt, and so is
    # a new revision of this script, since an attempt can fail on the tool rather than on what is declared (a bare
    # `bash` not on PATH, live on bioskop-nixos, 2026-10-22).
    if ! declared=$(declared_profiles "$info"); then
      echo "ndh-incus-container: $name's declared profiles could not be read: nothing delivered" >&2
      failed=1
      continue
    fi
    declared=$(printf 'tool\t%s\n%s' "$(readlink -f "${BASH_SOURCE[0]}")" "$declared")
    # A previous delivery whose commit never finished is finished first, so that only one delivery is ever set aside:
    # a failed delivery rolls back to the one aside there is. Not on an unhealthy container: that aside is its way back.
    if ! rest=$(leftovers "$name"); then
      echo "ndh-incus-container: $name's leftovers could not be listed: nothing delivered" >&2
      failed=1
      continue
    fi
    if [ -n "$rest" ]; then
      if ! healthy "$name"; then
        echo "ndh-incus-container: $name's previous delivery is unfinished and it is unhealthy on it: nothing delivered" >&2
        failed=1
        continue
      fi
      if ! commit "$name" "$(cat "$dir/lower.snapshot")"; then
        echo "ndh-incus-container: $name's previous delivery could not be committed: nothing delivered, the next converge resumes it" >&2
        failed=1
        continue
      fi
      echo "ndh-incus-container: $name's previous delivery committed: ${rest//$'\n'/; }"
    fi
    if [ -e "$dir/converge.failed" ] && [ "$(cat "$dir/converge.failed")" = "$declared" ]; then
      echo "ndh-incus-container: $name already failed on $toplevel; it stays on its previous system" >&2
      failed=1
      continue
    fi
    if ! snapshot=$(deliver_keep "$name"); then
      echo "ndh-incus-container: $name could not be delivered" >&2
      echo "$declared" >"$dir/converge.failed"
      # Stopped past its snapshot, the delivery has moved the previous system aside: put it back.
      for aside in "$dir"/.previous-*; do
        [ -d "$aside" ] || continue
        if rollback "$name" "${aside##*/.previous-}"; then
          echo "ndh-incus-container: $name is back on its previous system" >&2
        else
          echo "ndh-incus-container: $name's rollback FAILED: it needs a hand" >&2
        fi
      done
      failed=1
      continue
    fi
    if healthy "$name"; then
      # Healthy is the verdict: the system is kept whatever its cleanup does. An unfinished commit is resumed by the
      # next converge, and marks no failed attempt.
      rm -f "$dir/converge.failed"
      echo "ndh-incus-container: $name ← $toplevel, healthy, on snapshot $snapshot"
      if ! commit "$name" "$snapshot"; then
        echo "ndh-incus-container: $name's commit is unfinished; the next converge resumes it" >&2
        failed=1
      fi
    else
      echo "$declared" >"$dir/converge.failed"
      rollback "$name" "$snapshot" || echo "ndh-incus-container: $name's rollback FAILED: it needs a hand" >&2
      echo "ndh-incus-container: $name was unhealthy on $toplevel and is back on its previous system" >&2
      failed=1
    fi
  done
  return "$failed"
}

main() {
  case "${1:-}" in
  list) yq -p json -oy -r 'to_entries | .[] | .key + "  target=" + (.value.target // "standalone") + "  " + .value.toplevel' <<<"$INSTANCES" ;;
  create | deliver)
    [ -n "${2:-}" ] || usage
    "$1" "$2"
    ;;
  converge) converge ;;
  # deliver_keep's and rollback's own processes; not verbs of the operator's.
  _deliver-steps)
    [ -n "${2:-}" ] || usage
    deliver_steps "$2"
    ;;
  _rollback)
    [ -n "${3:-}" ] || usage
    rollback_steps "$2" "$3"
    ;;
  _commit)
    [ -n "${3:-}" ] || usage
    commit_steps "$2" "$3"
    ;;
  *) usage ;;
  esac
}

ndh::logger:command:run "@logTag@" main "$@"
