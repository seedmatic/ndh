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

zpool:expand() {
	local pool="$1"
	# Enable autoexpand so ZFS persists the new capacity across reboots.
	zpool set autoexpand=on "$pool" 2>/dev/null || true

	# Generate and execute zpool online -e for each top-level vdev group.
	# Uses zpool status --json + yq to discover leaf vdevs dynamically.
	# The partitions have already been grown by the systemd-repart units
	# ordered before initrd-root-fs.target (see zfs.nix:boot.initrd.systemd
	# with zfsOverlays.repart.enable), so this is a fast metadata update —
	# ZFS is just notified of the larger vdevs.
	pool="$pool" zpool status --json 2>/dev/null \
		| yq -p=json -r \
			'.pools[env(pool)].config.vdevs[]
			 | (if has("vdevs") then [.vdevs[].name] else [.name] end)
			 | "zpool online -e " + env(pool) + " " + join(" ")' \
		2>/dev/null \
		| bash -x \
		2>/dev/null || true
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
tank/nerd/nix/builds /nix/var/nix/builds
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

	# Partition growth is owned by the per-disk systemd-repart units emitted
	# by modules/nixos/zfs.nix (zfsOverlays.repart.enable = true). Those units
	# run before initrd-root-fs.target, so by the time this script executes
	# the tank/recover partitions already extend to end-of-disk and
	# `zpool online -e` in zpool:expand() just metadata-updates ZFS.

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
