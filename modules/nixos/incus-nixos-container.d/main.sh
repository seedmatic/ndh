#!/usr/bin/env bash
# ndh's NixOS containers. `main:create` is the operator's gesture; `main:reconcile` runs by itself after every
# switch and boot (ndh-incus-container-reconcile.service), and is the only thing that moves a container
# to a new system: the hand verbs below stay for the probe and for repairs.
#
#   ndh-incus-container list
#   ndh-incus-container main:create   {name}   dataset, project, incus:instance and its devices
#   ndh-incus-container deliver  {name}   restart the container on a snapshot of this generation's store
#   ndh-incus-container main:reconcile          deliver every declared container whose system differs, keep it if
#   ndh-incus-container main:reset     {name}   cold start: remove the container, its dataset and directory
#                                         main:healthy:check, restore the previous system if not
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
STORE_SCRIPT=@storeScript@
NIX_CONFIG=@nixConfig@
export NIX_CONFIG

main:stop::marked() {
	touch "$2/main:reconcile.stopped"
	incus stop --project "$PROJECT" "$1"
}

main:create() {
	if [[ $- != *e* ]]; then
		(
			set -e
			main:create "$@"
		)
		return $?
	fi
	local info dir dataset target privileged placement=() shift=()
	info=$(incus:instance "$1")
	eval "$(yq -p json -o=shell '{"dir": .dir, "dataset": .dataset, "target": .target, "privileged": .privileged} | with_entries(.value = (.value // ""))' <<<"$info")"
	# Unprivileged: the container's ids are mapped above the host's, so its declared disks are shifted
	# back. The store's four cannot be: an overlay below a recursive bind and the EROFS view refuse an
	# idmapped mount (measured on the probe, 2026-10-16). The container then sees its store as
	# `nobody`'s — readable, never writable, which it never needs.
	[ "$privileged" = true ] || shift=(shift=true)

	if [ "$(incus query /1.0/cluster | yq -p json -oy -r '.enabled')" = true ]; then
		[ -n "$target" ] || util:die "this member is clustered, and $1 states no target"
		placement=(--target "$target")
	elif [ -n "$target" ]; then
		util:die "this Incus is not clustered, so target $target cannot apply to $1"
	fi

	# Created here, not by disko: disko formats the pool at bringup and never revisits it.
	local made_dataset=0
	if ! zfs list -H "$dataset" >/dev/null 2>&1; then
		zfs create -p -o mountpoint="$dir" -o xattr=sa -o acltype=posixacl -o recordsize=16K "$dataset"
		made_dataset=1
	fi
	# Incus checks every disk device's source when it adds the device and when it starts the incus:instance.
	mkdir -p "$dir/root/nix" "$dir/upper" "$dir/view/nix/store" "$dir/view/nix/var/nix"

	incus project show "$PROJECT" >/dev/null 2>&1 || incus project create "$PROJECT"
	local where
	where=$(incus:locate "$1")
	[ "$where" = absent ] || incus:placed:check "$where" "$target" ||
		util:die "$1 already exists on member $where, not on its target $target: two guests declare the same name"
	if [ "$where" != absent ]; then
		echo "ndh-incus-container: $1 already exists in project $PROJECT"
		return
	fi

	# An empty rootfs: the system lives in /nix, and init is its profile. The rootfs keeps only the
	# mount points LXC needs.
	# A new project's default profile has no root disk, and Incus refuses an incus:instance without one.
	incus init --empty --project "$PROJECT" --storage "$POOL" "${placement[@]}" "$1" \
		-c security.privileged="$privileged" \
		-c cluster.evacuate=stop \
		-c boot.autostart=true \
		-c raw.lxc="$(util:raw_lxc:build "$dir")"
	# From here a failure deletes the instance: a half-configured one would make the next `main:create`
	# stop at "already exists".
	created="$1"
	trap 'incus delete --force --project "$PROJECT" "$created"' ERR
	for mountpoint in proc sys dev run tmp; do
		incus file create --project "$PROJECT" --type=directory "$1/$mountpoint"
	done
	local -A source
	local device src
	while read -r device src; do source[$device]=$src; done < <(overlay:devices:list "$dir")
	incus config device add --project "$PROJECT" "$1" nix disk \
		source="${source[nix]}" path=/nix recursive=true
	# The lower view's store is a mount of its own, and the kernel refuses a recursive read-only bind:
	# its two halves go in as two plain read-only binds.
	incus config device add --project "$PROJECT" "$1" nix-lower-store disk \
		source="${source["nix-lower-store"]}" path="$GUEST_LOWER/nix/store" readonly=true
	incus config device add --project "$PROJECT" "$1" nix-lower-db disk \
		source="${source["nix-lower-db"]}" path="$GUEST_LOWER/nix/var/nix" readonly=true
	incus config device add --project "$PROJECT" "$1" nix-upper disk \
		source="${source["nix-upper"]}" path="$GUEST_UPPER"
	local type keys
	for device in $(yq -p json -oy -r '.devices | keys | .[]' <<<"$info"); do
		# Incus takes the type as a positional argument and refuses `type=` among the keys.
		type=$(DEVICE="$device" yq -p json -oy -r '.devices[strenv(DEVICE)].type' <<<"$info")
		mapfile -t keys < <(DEVICE="$device" yq -p json -oy -r '.devices[strenv(DEVICE)] | to_entries | .[] | select(.key != "type") | .key + "=" + .value' <<<"$info")
		[ "$type" != disk ] || keys+=("${shift[@]}")
		incus config device add --project "$PROJECT" "$1" "$device" "$type" "${keys[@]}"
	done
	trap - ERR
	# Run by main:reconcile, what this create made, for its main:uncreate to remove that and nothing else: a dataset left from
	# before (an incus:instance deleted by hand, its store layer kept) is reused and never this main:create's (🛡️).
	if [ -n "${CONVERGE_CREATE_MARK:-}" ]; then
		if [ "$made_dataset" = 1 ]; then echo dataset >"$CONVERGE_CREATE_MARK"; else : >"$CONVERGE_CREATE_MARK"; fi
	fi
	echo "ndh-incus-container: $1 created on ${target:-this standalone member} — deliver it"
}

main:deliver() {
	if [[ $- != *e* ]]; then
		local snapshot
		snapshot=$( ( set -e; main:deliver "$@" ) 9>&1 1>&2 ) || return 1
		[ -n "$snapshot" ] || return 1
		echo "$snapshot"
		return 0
	fi
	local info dir toplevel store upper_root rw db snapshot aside entry runtime where target
	info=$(incus:instance "$1")
	eval "$(yq -p json -o=shell '{"dir": .dir, "toplevel": .toplevel, "hostStore": .hostStore, "target": .target} | with_entries(.value = (.value // ""))' <<<"$info")"
	store=$hostStore
	eval "$(yq -p json -o=shell '{"upperRoot": .upperRoot} | with_entries(.value = (.value // ""))' "$LAYER_CONTRACT")"
	upper_root="${upperRoot:-}"

	[ ! -e "$STORE_DEGRADED" ] || util:die "nerd-nixos's store is degraded — repair it before delivering"
	where=$(incus:locate "$1")
	[ "$where" != absent ] || util:die "$1 does not exist — main:create it first"
	incus:placed:check "$where" "$target" || util:die "$1 runs on member $where, not on its target $target — nothing touched"
	[ -e "$toplevel" ] || util:die "$toplevel is not in nerd-nixos's store — switch nerd-nixos to this generation first"
	[ "$(findmnt -no FSTYPE "$upper_root")" = zfs ] || util:die "$upper_root is not a ZFS dataset"
	[ "$(findmnt -no FSTYPE /nix/var/nix/db)" = zfs ] || util:die "/nix/var/nix/db is not a ZFS dataset"
	rw=$(findmnt -no SOURCE "$upper_root")
	db=$(findmnt -no SOURCE /nix/var/nix/db)

	if [ "$(incus query "/1.0/instances/$1/state?project=$PROJECT" | yq -p json -oy -r '.status')" != Stopped ]; then
		main:stop::marked "$1" "$dir"
	fi
	# Stopped first, so nothing in the container changes a component between this check and the mkdir.
	for entry in "${GUEST_LOWER#/}/nix/store" "${GUEST_LOWER#/}/nix/var/nix" "${GUEST_UPPER#/}"; do
		util:root:verify "$dir/root" "$entry"
	done
	# Before anything is snapshotted or moved: Incus can refuse it (an ETag race while it starts up,
	# measured), and a delivery that stops here has changed nothing.
	overlay:point "$1" "$dir" ||
		util:die "Incus refused $1's store devices or raw.lxc — nothing delivered, and the container stays STOPPED: run deliver again"
	systemctl stop "ndh-incus-container-store-$1.service"
	for entry in "$dir/root/nix/store" "$dir/view/nix/store"; do
		if mountpoint -q "$entry"; then util:die "$entry is still mounted"; fi
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
	[ -d "$upper_root/.zfs/snapshot/$snapshot/upper" ] || util:die "snapshot $snapshot has no upper"

	aside="$dir/.previous-$snapshot"
	mkdir -p "$aside/root/nix/var" "$aside/view/nix/var/nix"
	for entry in upper work upper.layer-set lower.snapshot lower.layers lower.frozen; do
		if [ -e "$dir/$entry" ]; then mv "$dir/$entry" "$aside/"; fi
	done
	if [ -e "$dir/root/nix/var/nix" ]; then mv "$dir/root/nix/var/nix" "$aside/root/nix/var/"; fi
	if [ -e "$dir/view/nix/var/nix/db" ]; then mv "$dir/view/nix/var/nix/db" "$aside/view/nix/var/nix/"; fi
	# A copy, WAL included, never the snapshot's own file: nix opens it normally, and SQLite's
	# `immutable` mode would ignore the WAL.
	mkdir -p "$dir/view/nix/var/nix/db"
	cp -a "/nix/var/nix/db/.zfs/snapshot/$snapshot/." "$dir/view/nix/var/nix/db"
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

	# The system's profile, then every other one the incus:instance declares, all host side: the container's root
	# cannot write in the host-owned /nix bind when it is idmapped (EPERM, silently, from the container's
	# activation: measured by 🎛️ on bioskop-nixos, 2026-10-22, for the bringup runtime profile).
	# The list first, its status checked: a `while … < <(yq …)` loses yq's. Each profile's parent is made
	# here, root's own: nix-env makes none, and the old /nix/var/nix, its per-user/root included, went aside.
	# The snapshot carries each package, so `nix copy` copies nothing; it stays as the check that it does.
	# The source is nerd-nixos's own store, which built or validated every path; most carry no
	# signature, so a checked copy would refuse the first path of any delta.
	local profiles profile parent
	profiles=$(nix:profile:list "$info")
	while IFS=$'\t' read -r profile runtime; do
		[ -n "$profile" ] || continue
		parent=$(dirname "${profile#/}")
		util:root:verify "$dir/root" "$parent"
		# 0755 at every level it makes, whatever the caller's umask; `-m` would apply to the deepest one only.
		(umask 022 && mkdir -p "$dir/root/$parent")
		nix copy --no-check-sigs --to "$store" "$runtime"
		nix-env --store "$store" -p "$dir/root$profile" --set "$runtime"
	done <<<"$profiles"
	# Incus validates profiles at start; nerd-nixos's GC, freeze and compaction keep what a container runs.
	# nerd-nixos's GC, freeze and compaction keep what a container runs.
	mkdir -p "$GCROOTS"
	ln -sfn "$toplevel" "$GCROOTS/$1"
	incus start --project "$PROJECT" "$1"
	# Return the snapshot through fd 9 when the caller opened it (the `deliver` wrapper), otherwise through stdout (reconcile, main:deliver).
	if { true >&9; } 2>/dev/null; then echo "$snapshot" >&9; else echo "$snapshot"; fi
}

main:delivery:validate() {
	[[ $2 =~ ^ndh-incus-$1-[0-9]{8}T[0-9]{6}Z$ ]] || util:die "'$2' is not a delivery snapshot of $1"
}

main:delivery:snapshot:list() {
	zfs list -H -t snapshot -o name "$2" "$3" | grep -E "@ndh-incus-$1-[0-9]{8}T[0-9]{6}Z\$" || true
	zfs:snapshot:list "$4" "$1"
}

main:bringup() {
	if [[ $- != *e* ]]; then
		(
			set -e
			main:bringup "$@"
		)
		return $?
	fi
	local info dir
	info=$(incus:instance "$1")
	eval "$(yq -p json -o=shell '{"dir": .dir} | with_entries(.value = (.value // ""))' <<<"$info")"
	# Its devices on its own dir first.
	# 2026-10-25), and its start would find no store there.
	overlay:point "$1" "$dir"
	if ! mountpoint -q "$dir/root/nix/store" || ! mountpoint -q "$dir/view/nix/store"; then
		systemctl start "ndh-incus-container-store-$1.service"
	fi
	incus start --project "$PROJECT" "$1"
}

main:create::tracked() { CONVERGE_CREATE_MARK="$2" "$BASH" "${BASH_SOURCE[0]}" main:create "$1"; }

main:reset() {
	if [[ $- != *e* ]]; then
		(
			set -e
			main:reset "$@"
		)
		return $?
	fi
	local name=$1 info dir dataset where
	info=$(incus:instance "$name") || {
		echo "ndh-incus-container: $name is not declared" >&2
		return 1
	}
	eval "$(yq -p json -o=shell '{"dir": .dir, "dataset": .dataset} | with_entries(.value = (.value // ""))' <<<"$info")"
	where=$(incus:locate "$name" 2>/dev/null || echo absent)
	if [ "$where" != absent ]; then
		incus stop --force --project "$PROJECT" "$name" 2>/dev/null || true
		incus delete --force --project "$PROJECT" "$name" 2>/dev/null || true
	fi
	systemctl stop "ndh-incus-container-store-$name.service" 2>/dev/null || true
	if zfs list -H "$dataset" >/dev/null 2>&1; then
		zfs destroy -r "$dataset" 2>/dev/null || true
	fi
	rm -rf --one-file-system "${dir:?}" 2>/dev/null || true
	echo "ndh-incus-container: $name reset (container, dataset, directory) — run main:reconcile to recreate" >&2
}

main:uncreate() {
	if [[ $- != *e* ]]; then
		(
			set -e
			main:uncreate "$@"
		)
		return $?
	fi
	local info dir dataset upper_root rw db snap state
	info=$(incus:instance "$1")
	eval "$(yq -p json -o=shell '{"dir": .dir, "dataset": .dataset} | with_entries(.value = (.value // ""))' <<<"$info")"
	rollback=$(printf '%s' "$info" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("rollback", True))')
	if [ "$rollback" = "False" ] || [ "$rollback" = "false" ]; then
		echo "ndh-incus-container: $1 has rollback disabled: uncreate skipped" >&2
		return 2
	fi
	[ -e "$dir/main:reconcile.created" ] || util:die "$1 was not created by reconcile: nothing removed"
	[ -z "$2" ] || main:delivery:validate "$1" "$2"
	eval "$(yq -p json -o=shell '{"upperRoot": .upperRoot} | with_entries(.value = (.value // ""))' "$LAYER_CONTRACT")"
	upper_root="${upperRoot:-}"
	rw=$(findmnt -no SOURCE "$upper_root")
	db=$(findmnt -no SOURCE /nix/var/nix/db)
	if [ "$(incus:locate "$1")" != absent ]; then
		incus stop --force --project "$PROJECT" "$1" || true
		incus delete --force --project "$PROJECT" "$1"
	fi
	systemctl stop "ndh-incus-container-store-$1.service" || true
	if [ -n "$2" ]; then
		for snap in "$rw@$2" "$db@$2"; do
			if zfs list -H -t snapshot "$snap" >/dev/null 2>&1; then zfs:snapshot:destroy "$snap"; fi
		done
		for state in $(yq -p json -oy -r '(.stateDatasets // []) | .[]' <<<"$info"); do
			if zfs list -H -t snapshot "$state@$2" >/dev/null 2>&1; then zfs:snapshot:destroy -r "$state@$2"; fi
		done
	fi
	if [ "$(cat "$dir/main:reconcile.created")" = dataset ]; then
		if zfs list -H "$dataset" >/dev/null 2>&1; then zfs destroy -r "$dataset"; fi
		rm -rf --one-file-system "${dir:?}"
		echo "ndh-incus-container: $1 removed, its dataset with it" >&2
	else
		# Kept as it was before converge: its first delivery set its store layer aside, which goes back. That delivery's
		# is the one aside a never-delivered container can have, whether or not it got as far as naming its snapshot.
		local aside
		for aside in "$dir"/.previous-*; do
			if [ -d "$aside" ]; then main:restore::aside "$dir" "$aside"; fi
		done
		rm -f "$dir/main:reconcile.created"
		echo "ndh-incus-container: $1 removed; its dataset $dataset, older than it, kept" >&2
	fi
}

main:leftovers:list() {
	local info dir upper_root rw db current
	info=$(incus:instance "$1") || return 1
	eval "$(yq -p json -o=shell '{"dir": .dir} | with_entries(.value = (.value // ""))' <<<"$info")" || return 1
	eval "$(yq -p json -o=shell '{"upperRoot": .upperRoot} | with_entries(.value = (.value // ""))' "$LAYER_CONTRACT")" || return 1
	upper_root="${upperRoot:-}"
	rw=$(findmnt -no SOURCE "$upper_root") || return 1
	db=$(findmnt -no SOURCE /nix/var/nix/db) || return 1
	# Never delivered (created, by hand or by main:reconcile), no delivery pair is the current one; the rest is listed as ever.
	current=
	if [ -e "$dir/lower.snapshot" ]; then
		current=$(cat "$dir/lower.snapshot") || return 1
		main:delivery:validate "$1" "$current"
	fi
	zfs list -H -t snapshot -o name "$rw" "$db" | grep -E "@ndh-incus-$1-[0-9]{8}T[0-9]{6}Z\$" |
		grep -vxF -e "$rw@${current:-}" -e "$db@${current:-}" || true
	zfs:snapshot:list "$info" "$1"
	local aside
	for aside in "$dir"/.previous-*; do [ ! -e "$aside" ] || echo "$aside"; done
}

main:commit() {
	if [[ $- != *e* ]]; then
		(
			set -e
			main:commit "$@"
		)
		return $?
	fi
	local info dir upper_root rw db old
	main:delivery:validate "$1" "$2"
	info=$(incus:instance "$1")
	eval "$(yq -p json -o=shell '{"dir": .dir} | with_entries(.value = (.value // ""))' <<<"$info")"
	eval "$(yq -p json -o=shell '{"upperRoot": .upperRoot} | with_entries(.value = (.value // ""))' "$LAYER_CONTRACT")"
	upper_root="${upperRoot:-}"
	rw=$(findmnt -no SOURCE "$upper_root")
	db=$(findmnt -no SOURCE /nix/var/nix/db)
	for old in $(zfs list -H -t snapshot -o name "$rw" "$db" | grep -E "@ndh-incus-$1-[0-9]{8}T[0-9]{6}Z\$" |
		grep -vxF -e "$rw@$2" -e "$db@$2" || true); do
		zfs:snapshot:destroy "$old"
	done
	for old in $(zfs:snapshot:list "$info" "$1"); do zfs:snapshot:destroy -r "$old"; done
	for old in "$dir"/.previous-*; do rm -rf --one-file-system "$old"; done
}

main:restore::aside() {
	local dir=$1 aside=$2 entry
	for entry in upper work upper.layer-set lower.snapshot lower.layers lower.frozen; do
		rm -rf --one-file-system "${dir:?}/$entry"
		if [ -e "$aside/$entry" ]; then mv "$aside/$entry" "$dir/"; fi
	done
	rm -rf --one-file-system "$dir/root/nix/var/nix" "$dir/view/nix/var/nix/db"
	if [ -e "$aside/root/nix/var/nix" ]; then mv "$aside/root/nix/var/nix" "$dir/root/nix/var/"; fi
	if [ -e "$aside/view/nix/var/nix/db" ]; then mv "$aside/view/nix/var/nix/db" "$dir/view/nix/var/nix/"; fi
	rm -rf --one-file-system "$aside"
}

main:rollback() {
	if [[ $- != *e* ]]; then
		(
			set -e
			main:rollback "$@"
		)
		return $?
	fi
	info=$(incus:instance "$1")
	rollback=$(printf '%s' "$info" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("rollback", True))')
	enabled="${rollback:-}"
	if [ -z "$enabled" ] || [ "$enabled" = "false" ]; then
		echo "ndh-incus-container: $1 is unhealthy but rollback SKIPPED (NDH_INCUS_CONTAINER_ROLLBACK set); container stays on new system for debugging" >&2
		return 0
	fi
	local info dir toplevel upper_root rw db aside entry previous state fs
	info=$(incus:instance "$1")
	eval "$(yq -p json -o=shell '{"dir": .dir, "toplevel": .toplevel} | with_entries(.value = (.value // ""))' <<<"$info")"
	eval "$(yq -p json -o=shell '{"upperRoot": .upperRoot} | with_entries(.value = (.value // ""))' "$LAYER_CONTRACT")"
	upper_root="${upperRoot:-}"
	rw=$(findmnt -no SOURCE "$upper_root")
	db=$(findmnt -no SOURCE /nix/var/nix/db)
	# The snapshot names a path and the datasets rolled back and destroyed: checked before any of them is touched.
	main:delivery:validate "$1" "$2"
	aside="$dir/.previous-$2"
	[ -d "$aside" ] || util:die "nothing kept for $1 at $aside — no rollback possible"

	touch "$dir/main:reconcile.stopped"
	incus stop --force --project "$PROJECT" "$1" || true
	systemctl stop "ndh-incus-container-store-$1.service"
	main:restore::aside "$dir" "$aside"
	# The data as it was when the container stopped for this delivery: `zfs rollback` is per filesystem,
	# so every one under the declared dataset, each to its own snapshot of the recursive pair.
	for state in $(yq -p json -oy -r '(.stateDatasets // []) | .[]' <<<"$info"); do
		for fs in $(zfs list -H -o name -r -t filesystem "${state:?}"); do
			zfs rollback -r "$fs@$2"
		done
		zfs:snapshot:destroy -r "$state@$2"
	done
	zfs:snapshot:destroy "$rw@$2"
	zfs:snapshot:destroy "$db@$2"
	previous=$(cat "$dir/lower.snapshot" 2>/dev/null || true)
	[ -n "$previous" ] || util:die "$1 had no delivery before $2: it stays STOPPED"
	systemctl start "ndh-incus-container-store-$1.service"
	# The GC root follows what runs again: the previous system is the profile's target.
	mkdir -p "$GCROOTS"
	ln -sfn "$(readlink -f "$dir/root/nix/var/nix/profiles/system")" "$GCROOTS/$1"
	incus start --project "$PROJECT" "$1"
	echo "ndh-incus-container: $1 rolled back from $toplevel to snapshot $previous"
}

main:healthy:check() {
	local info deadline units unit kind state result
	info=$(incus:instance "$1")
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
	# The list first, its status checked: `main:healthy:check` runs under `if`, errexit off, and an empty list read
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

main:reconcile:create() {
	local name=$1 dir=$2 target=$3
	# main:create removes its own half-made incus:instance (its ERR trap); an empty dataset it left is reused by the next try.
	if ! main:create::tracked "$name" "$dir/main:reconcile.created"; then
		echo "ndh-incus-container: $name could not be created: the next main:reconcile tries again" >&2
		return 1
	fi
	return 0
}

main:reconcile:stopped() {
	local name=$1 dir=$2
	# Only what main:reconcile stopped: one the operator stopped stays stopped, the gesture that must stick (🛡️).
	if [ ! -e "$dir/main:reconcile.stopped" ]; then
		echo "ndh-incus-container: $name is stopped, not by reconcile: held by the operator, left stopped"
		return 1
	fi
	if ! main:bringup "$name"; then
		echo "ndh-incus-container: $name holds its declared state but could not be started" >&2
		return 1
	fi
	if ! main:healthy:check "$name"; then
		echo "ndh-incus-container: $name was stopped, and is unhealthy started on its declared system" >&2
		return 1
	fi
	rm -f "$dir/main:reconcile.stopped"
	echo "ndh-incus-container: $name was stopped: started on its declared system"
	return 0
}

main:reconcile:commit() {
	local name=$1 dir=$2 rest unfinished=0
	if ! rest=$(main:leftovers:list "$name"); then
		echo "ndh-incus-container: $name's main:leftovers:list could not be listed" >&2
		unfinished=1
	elif [ -n "$rest" ]; then
		if ! main:healthy:check "$name"; then
			echo "ndh-incus-container: $name holds its declared state but is unhealthy: its previous delivery is kept" >&2
			unfinished=1
		elif ! main:commit "$name" "$(cat "$dir/lower.snapshot")"; then
			echo "ndh-incus-container: $name's commit is still unfinished; the next main:reconcile resumes it" >&2
			unfinished=1
		else
			echo "ndh-incus-container: $name's previous delivery committed: ${rest//$'\n'/; }"
		fi
	fi
	# What holds needs no attempt marker: a stale one (a main:commit that died after a healthy check delivery) goes.
	if [ "$unfinished" = 1 ]; then return 1; else rm -f "$dir/main:reconcile.failed" "$dir/main:reconcile.stopped"; fi
	return 0
}

main:reconcile() {
	local name info dir toplevel target where declared wrong rest snapshot aside failed=0
	for name in $(yq -p json -oy -r 'keys | .[]' <<<"$INSTANCES"); do
		info=$(incus:instance "$name")
		eval "$(yq -p json -o=shell '{"dir": .dir, "toplevel": .toplevel, "target": .target} | with_entries(.value = (.value // ""))' <<<"$info")"
		if ! where=$(incus:locate "$name"); then
			echo "ndh-incus-container: $name's location could not be read: nothing delivered" >&2
			failed=1
			continue
		fi
		# Another member's incus:instance of the same name is a declaration error, never this guest's to deliver: stopping it
		# would stop the other guest's container. Shown, never skipped silently (🧭).
		if [ "$where" != absent ] && ! incus:placed:check "$where" "$target"; then
			echo "ndh-incus-container: $name runs on member $where, not on its target $target: two guests declare the same name — nothing touched" >&2
			failed=1
			continue
		fi
		# Declared and absent from the whole cluster: main:reconcile creates it on its own member, then delivers it as any
		# other (the operator's decision, 2026-10-24). main:reconcile.created marks it converge's: a delivery that fails or is
		# unhealthy then removes it, there being no previous system to go back to.
		if [ "$where" = absent ]; then
			main:reconcile:create "$name" "$dir" "$target" || { failed=1; continue; }
			echo "ndh-incus-container: $name created on ${target:-this standalone member}"
		fi
		# Every declared profile, the system's and the others, resolved on both sides (a profile is a chain of
		# links: system → system-N-link → the store path). One that is not means a delivery: the container's scripts
		# read those profiles, so one set under a running container would go unchecked by any health test.
		if wrong=$(nix:profile:check "$name"); then
			# Holding its declared state yet stopped (a switch restarted incus before its store unit, and incus's own
			# autostart was refused by the pre-start hook: live, 2026-10-25): its store, then itself, then its health.
			if [ "$(incus query "/1.0/instances/$name/state?project=$PROJECT" | yq -p json -oy -r '.status')" = Stopped ]; then
				main:reconcile:stopped "$name" "$dir" || { failed=1; continue; }
			fi
			# A commit that stopped half-way (a snapshot busy, live 2026-10-22) left the previous delivery behind; this
			# run finishes it, once the container proves main:healthy:check on what it runs: before that, the aside is its way back.
			main:reconcile:commit "$name" "$dir" || { failed=1; continue; }
			echo "ndh-incus-container: $name holds its declared system and profiles"
			continue
		else
			echo "ndh-incus-container: $name is not holding its declared system ($wrong)" >&2
			wrong=""
		fi
		# Stopped by the operator, it is held: a delivery would start it (🛡️). One main:reconcile stopped is converge's own.
		if [ -e "$dir/lower.snapshot" ] && [ ! -e "$dir/main:reconcile.stopped" ] &&
			[ "$(incus query "/1.0/instances/$name/state?project=$PROJECT" | yq -p json -oy -r '.status')" = Stopped ]; then
			echo "ndh-incus-container: $name is stopped, not by converge: held by the operator, not delivered"
			continue
		fi
		echo "ndh-incus-container: $name to deliver: ${wrong//$'\n'/; }" >&2
		# One attempt per declared state and per delivering tool: a changed profile alone is a new attempt, and so is
		# a new revision of this script, since an attempt can fail on the tool rather than on what is declared (a bare
		# `bash` not on PATH, live on bioskop-nixos, 2026-10-22).
		if ! declared=$(nix:profile:list "$info"); then
			echo "ndh-incus-container: $name's declared profiles could not be read: nothing delivered" >&2
			failed=1
			continue
		fi
		declared=$(printf 'tool\t%s\n%s' "$(readlink -f "${BASH_SOURCE[0]}")" "$declared")
		# A previous delivery whose commit never finished is finished first, so that only one delivery is ever set aside:
		# a failed delivery rolls back to the one aside there is. Not on an unhealthy container: that aside is its way back.
		# Only on a container that was delivered: one never delivered has no delivery of its own to finish, and what it
		# finds is older than it, never converge's to main:commit (🛡️: a reused dataset's).
		rest=
		if [ -e "$dir/lower.snapshot" ] && ! rest=$(main:leftovers:list "$name"); then
			echo "ndh-incus-container: $name's main:leftovers:list could not be listed: nothing delivered" >&2
			failed=1
			continue
		fi
		if [ -n "$rest" ]; then
			if ! main:healthy:check "$name"; then
				echo "ndh-incus-container: $name's previous delivery is unfinished and it is unhealthy on it: nothing delivered" >&2
				failed=1
				continue
			fi
			if ! main:commit "$name" "$(cat "$dir/lower.snapshot")"; then
				echo "ndh-incus-container: $name's previous delivery could not be committed: nothing delivered, the next main:reconcile resumes it" >&2
				failed=1
				continue
			fi
			echo "ndh-incus-container: $name's previous delivery committed: ${rest//$'\n'/; }"
		fi
		if [ -e "$dir/main:reconcile.failed" ] && [ "$(cat "$dir/main:reconcile.failed")" = "$declared" ]; then
			echo "ndh-incus-container: $name already failed on $toplevel; it stays on its previous system" >&2
			echo "ndh-incus-container: to retry, remove $dir/main:reconcile.failed and re-run main:reconcile" >&2
			# Stays on it RUNNING: main:reconcile left it down (a rollback whose start failed too), so it brings it up there.
			if [ -e "$dir/main:reconcile.stopped" ] &&
				[ "$(incus query "/1.0/instances/$name/state?project=$PROJECT" | yq -p json -oy -r '.status')" = Stopped ]; then
				if main:bringup "$name" && main:healthy:check "$name"; then
					rm -f "$dir/main:reconcile.stopped"
					echo "ndh-incus-container: $name was down: started on its previous system"
				else
					echo "ndh-incus-container: $name could not be started on its previous system either: it needs a hand" >&2
				fi
			fi
			failed=1
			continue
		fi
		if ! snapshot=$(main:deliver "$name"); then
			echo "ndh-incus-container: $name could not be delivered" >&2
			if [ -e "$dir/main:reconcile.created" ]; then
				rc=0
				main:uncreate "$name" "$(cat "$dir/lower.snapshot" 2>/dev/null || true)" || rc=$?
				if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
					echo "ndh-incus-container: $name could not be removed: it needs a hand" >&2
				fi
				failed=1
				continue
			fi
			echo "$declared" >"$dir/main:reconcile.failed"
			# Stopped past its snapshot, the delivery has moved the previous system aside: put it back.
			for aside in "$dir"/.previous-*; do
				[ -d "$aside" ] || continue
				if ! main:rollback "$name" "${aside##*/.previous-}"; then
					echo "ndh-incus-container: $name's rollback FAILED: it needs a hand" >&2
				else
					echo "ndh-incus-container: $name is back on its previous system" >&2
				fi
			done
			failed=1
			continue
		fi
		if main:healthy:check "$name"; then
			# Healthy is the verdict: the system is kept whatever its cleanup does. An unfinished main:commit is resumed by the
			# next main:reconcile, and marks no failed attempt.
			rm -f "$dir/main:reconcile.failed" "$dir/main:reconcile.created" "$dir/main:reconcile.stopped"
			echo "ndh-incus-container: $name ← $toplevel, main:healthy:check, on snapshot $snapshot"
			if ! main:commit "$name" "$snapshot"; then
				echo "ndh-incus-container: $name's commit is unfinished; the next main:reconcile resumes it" >&2
				failed=1
			fi
		elif [ -e "$dir/main:reconcile.created" ]; then
			rc=0
			main:uncreate "$name" "$snapshot" || rc=$?
			case "$rc" in
				0) echo "ndh-incus-container: $name was unhealthy on its first system and is removed" >&2 ;;
				2) echo "ndh-incus-container: $name is unhealthy on its first system but rollback is disabled: kept for debugging" >&2 ;;
				*) echo "ndh-incus-container: $name could not be removed: it needs a hand" >&2 ;;
			esac
			failed=1
		else
			echo "$declared" >"$dir/main:reconcile.failed"
			if main:rollback "$name" "$snapshot"; then
				echo "ndh-incus-container: $name is back on its previous system" >&2
			else
				echo "ndh-incus-container: $name's rollback FAILED: it needs a hand" >&2
			fi
			failed=1
		fi
	done
	return "$failed"
}

main:list() {
	yq -p json -oy -r 'to_entries | .[] | .key + "  target=" + (.value.target // "standalone") + "  " + .value.toplevel' <<<"$INSTANCES"
}

deliver() {
	local snapshot
	snapshot=$(main:deliver "$1")
	main:commit "$1" "$snapshot"
	echo "ndh-incus-container: $1 ← $(util:field "$(incus:instance "$1")" toplevel), on snapshot $snapshot"
}

main() {
	case "${1:-}" in
	main:list | list) main:list ;;
	main:create | create | main:deliver | deliver)
		[ -n "${2:-}" ] || util:usage
		case "$1" in
		create) main:create "$2" ;;
		deliver) main:deliver "$2" ;;
		*) "$1" "$2" ;;
		esac
		;;
	main:reconcile | reconcile) main:reconcile ;;
	main:reset | reset)
		[ -n "${2:-}" ] || util:usage
		main:reset "$2"
		;;
	*) util:usage ;;
	esac
}

ndh::logger:command:run "@logTag@" main "$@"
