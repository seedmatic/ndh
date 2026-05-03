#!/usr/bin/env -S bash -euo pipefail
# shellcheck source=/dev/null
source @nixBashTrampoline@

# zpool-init: import and expand pre-provisioned ZFS pools at VM boot.
#
# ZFS pools and datasets are created during the Nix bringup build (nested QEMU).
# This script's sole runtime responsibilities are:
#   1. Verify required partition labels are present (sanity check)
#   2. Import pools if not already imported
#   3. Expand pools to claim new space when disk images have been grown
#   4. Reconcile ZFS mountpoint properties if needed

zpool:init:configure() {
	ZFS_DISK_TANK1="${ZFS_DISK_TANK1:-/dev/vdb}"
	ZFS_DISK_TANK2="${ZFS_DISK_TANK2:-/dev/vdc}"
	ZFS_DISK_TANK3="${ZFS_DISK_TANK3:-/dev/vdd}"
	ZFS_DISK_RECOVER="${ZFS_DISK_RECOVER:-/dev/vde}"
	EXPECTED_POOLS=(tank recover)
	EXPECTED_TANK_PARTS=(
		"/dev/disk/by-partlabel/tank1"
		"/dev/disk/by-partlabel/tank2"
		"/dev/disk/by-partlabel/tank3"
	)
	EXPECTED_RECOVER_PARTS=(
		"/dev/disk/by-partlabel/recover"
	)
}

zpool:import() {
	local pool="$1"
	zpool import -N "$pool" >/dev/null 2>&1
}

disk:partition:grow-last() {
	# Grow the last partition on a disk to fill all available space.
	# This is needed when the .asif disk image has been resized on the host
	# but the partition table still reflects the original bringup size.
	#
	# Uses sgdisk:
	#   -e  : move backup GPT header to end of disk (fix after disk resize)
	#   -d N: delete last partition (preserving its start sector and type)
	#   -n N:start:end : recreate from same start to end-of-disk (-1)
	#   -c N:label     : restore original partition name
	#   -t N:typeGUID  : restore original type GUID
	local disk="$1"
	local sgdisk="${SGDISK_BIN:-sgdisk}"
	local blockdev="${BLOCKDEV_BIN:-blockdev}"

	[[ -b "$disk" ]] || return 0

	# Find last partition number
	local last_part_num
	last_part_num="$("$sgdisk" --print "$disk" 2>/dev/null | awk '/^Number/{found=1; next} found && /^[[:space:]]*[0-9]/{last=$1} END{print last}')"
	[[ -n "$last_part_num" ]] || return 0

	# Get current last sector and disk's last usable sector
	local part_start part_end disk_last_usable part_name part_type
	part_start="$("$sgdisk" --info="$last_part_num" "$disk" 2>/dev/null | awk '/First sector:/{print $3}')"
	part_end="$("$sgdisk" --info="$last_part_num" "$disk" 2>/dev/null | awk '/Last sector:/{print $3}')"
	disk_last_usable="$("$sgdisk" --print "$disk" 2>/dev/null | awk '/last usable sector is/{print $NF}')"
	part_name="$("$sgdisk" --info="$last_part_num" "$disk" 2>/dev/null | awk -F': ' '/Partition name:/{gsub(/'\''/, "", $2); print $2}')"
	part_type="$("$sgdisk" --info="$last_part_num" "$disk" 2>/dev/null | awk '/Partition GUID code:/{print $4}')"

	if [[ -z "$part_start" || -z "$part_end" || -z "$disk_last_usable" ]]; then
		: "[zpool-init][WARN] could not read partition info for $disk part $last_part_num; skipping grow"
		return 0
	fi

	if [[ "$part_end" -ge "$disk_last_usable" ]]; then
		: "[zpool-init][INFO] $disk part $last_part_num already at end of disk; no grow needed"
		return 0
	fi

	: "[zpool-init][INFO] growing $disk part $last_part_num from sector $part_end to $disk_last_usable"

	# Move backup GPT to end of enlarged disk, then extend partition
	"$sgdisk" -e "$disk" 2>/dev/null || true
	"$sgdisk" \
		-d "$last_part_num" \
		-n "${last_part_num}:${part_start}:-1" \
		-c "${last_part_num}:${part_name}" \
		-t "${last_part_num}:${part_type}" \
		"$disk"

	# Inform the kernel of the new partition table
	"$blockdev" --rereadpt "$disk" 2>/dev/null || true
	udevadm settle --timeout=10 2>/dev/null || true
}

zpool:expand() {
	local pool="$1"
	# autoexpand=on makes ZFS automatically claim new space when the underlying
	# device grows. Since disk:partition:grow-last runs before pool import,
	# ZFS sees the full partition size at import time and expands automatically.
	# No explicit zpool online -e needed.
	zpool set autoexpand=on "$pool" 2>/dev/null || true
}

zpool:zfs:set_legacy_mountpoints_for_rke2_paths() {
	local dataset
	local mountpoint

	zfs list -H -o name,mountpoint -r tank/rke2 2>/dev/null | while read -r dataset mountpoint; do
		case "$mountpoint" in
		legacy | none | -)
			continue
			;;
		/*)
			zfs set mountpoint=legacy "$dataset" || : "[zpool-init][WARN] failed to set legacy on $dataset"
			;;
		esac
	done
}

zpool:zfs:reconcile_nerd_mountpoints() {
	local dataset
	local desired

	while read -r dataset desired; do
		if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
			continue
		fi

		if [ "$(zfs get -H -o value mountpoint "$dataset")" != "$desired" ]; then
			zfs set "mountpoint=$desired" "$dataset" || : "[zpool-init][WARN] failed to set mountpoint=$desired on $dataset"
		fi
	done <<'EOF'
tank/nerd/root /
tank/nerd/nix /nix
tank/nerd/var/cache /var/cache
tank/nerd/var/log /var/log
tank/nerd/var/lib/buildkit /var/lib/buildkit
tank/nerd/var/lib/containerd /var/lib/containerd
tank/nerd/var/lib/incus /var/lib/incus
tank/nerd/var/lib/lxc /var/lib/lxc
tank/nerd/var/lib/nixos-containers /var/lib/nixos-containers
tank/nerd/var/lib/nix-snapshotter /var/lib/nix-snapshotter
tank/nerd/var/tmp /var/tmp
tank/nerd/persist /persist
tank/nerd/srv /srv
EOF
}

zpool:is_imported() {
	local pool="$1"
	zpool list -H -o name "$pool" >/dev/null 2>&1
}

zpool:is_discoverable() {
	local pool="$1"
	zpool import 2>/dev/null | awk -v pool="$pool" '$1 == "pool:" && $2 == pool { found = 1 } END { exit(found ? 0 : 1) }'
}

zpool:partlabels:available() {
	local part
	local missing=0

	for part in "${EXPECTED_TANK_PARTS[@]}" "${EXPECTED_RECOVER_PARTS[@]}"; do
		if [ ! -e "$part" ]; then
			: "[zpool-init][WARN] expected partlabel unavailable: $part"
			missing=1
		fi
	done

	[ "$missing" -eq 0 ]
}

zpool:init:main() {
	set -euxo pipefail
	zpool:init:configure

	# Sanity check: partition labels must exist (created during bringup build)
	if ! zpool:partlabels:available; then
		: "[zpool-init][ERROR] expected ZFS partition labels missing — was the bringup disk image used?"
		exit 1
	fi

	# Grow last partition on each data disk to fill any extra space added when
	# the host expanded the .asif disk image. Must happen before ZFS import so
	# that zpool online -e can actually claim the new sectors.
	for disk in "$ZFS_DISK_TANK1" "$ZFS_DISK_TANK2" "$ZFS_DISK_TANK3" "$ZFS_DISK_RECOVER"; do
		[[ -b "$disk" ]] && disk:partition:grow-last "$disk" || true
	done

	# Import all expected pools and expand them to claim any grown disk space
	import_failures=0
	for pool in "${EXPECTED_POOLS[@]}"; do
		if zpool:is_imported "$pool"; then
			: "[zpool-init][INFO] pool already imported: $pool"
			zpool:expand "$pool"
			continue
		fi

		if ! zpool:is_discoverable "$pool"; then
			: "[zpool-init][ERROR] expected pool not discoverable: $pool"
			import_failures=1
			continue
		fi

		if ! zpool:import "$pool"; then
			: "[zpool-init][ERROR] failed to import pool: $pool"
			import_failures=1
			continue
		fi

		zpool:expand "$pool"
	done

	if [ "$import_failures" -ne 0 ]; then
		: "[zpool-init][ERROR] one or more ZFS pools could not be imported"
		exit 1
	fi

	# Reconcile ZFS mountpoint properties (idempotent)
	: "[zpool-init][INFO] reconciling ZFS mountpoint properties"
	if zpool list -H -o name tank >/dev/null 2>&1; then
		zpool:zfs:set_legacy_mountpoints_for_rke2_paths
		zpool:zfs:reconcile_nerd_mountpoints
	fi

	: "[zpool-init][INFO] ZFS pool import and expansion complete"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
	zpool:init:configure
	: "[zpool-init][INFO] sourced mode; helper functions loaded"
else
	ndh::logger:command:run "nixos.zfs.zpool-init" zpool:init:main "$@"
fi
