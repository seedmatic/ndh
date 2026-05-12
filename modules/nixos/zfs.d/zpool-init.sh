#!/usr/bin/env -S bash -euo pipefail
# shellcheck source=/dev/null
source @nixBashTrampoline@

# zpool-init: expand pre-provisioned ZFS pools and reconcile dataset
# mountpoints after the pools are already imported.
#
# Pool import is NOT this script's responsibility.  NixOS generates
# `zfs-import-<pool>.service` units from `boot.zfs.extraPools`, and those
# services run in both the initrd and stage-2.  By the time this unit
# runs (After=zfs-import.target) the `tank` and `recover` pools are
# already imported.  A prior implementation tried to own the import and
# raced against NixOS's services — in one boot, `zpool import` (which
# only lists *unimported* pools) showed `tank` as "not discoverable"
# because NixOS had just imported it, and this script failed with
# "expected pool not discoverable".
#
# Responsibilities now:
#   1. For each expected pool: `autoexpand=on` + `zpool online -e` on
#      every leaf vdev (picks up new sectors after systemd-repart).
#   2. Reconcile ZFS dataset mountpoint properties (legacy for rke2,
#      explicit paths under tank/nerd).

zpool:init:configure() {
	EXPECTED_POOLS=(tank recover)
}

zpool:expand() {
	local pool="$1"

	# Enable autoexpand so ZFS persists the new capacity across reboots.
	if ! zpool set autoexpand=on "$pool"; then
		: "[zpool-init][WARN] failed to set autoexpand=on on $pool"
	fi

	# Enumerate leaf vdev *paths* and hand them to `zpool online -e`.
	# Partition growth is owned by the per-disk systemd-repart initrd
	# units, so all this has to do is tell ZFS to pick up the new sector
	# count.
	#
	# A "leaf vdev" is any object under `.pools.<pool>` whose shape
	# carries a `.path` — that's the one invariant across raidz / mirror
	# / single-disk layouts.  Filtering on `vdev_type == "disk"` would
	# miss the single-disk `recover` pool, which reports its leaf as
	# `vdev_type: root`.
	local leaves
	leaves="$(zpool status --json "$pool" \
		| yq -p=json -r \
			'[.. | select(has("path")) | .path] | join(" ")')"

	if [ -z "$leaves" ]; then
		: "[zpool-init][WARN] could not enumerate leaf vdevs for $pool; skipping online -e"
		return 0
	fi

	: "[zpool-init][INFO] bringing leaf vdevs online with expand on $pool: $leaves"
	# Intentionally no error suppression: if `zpool online -e` fails the
	# journal should carry the reason.  Subsequent runs are cheap metadata
	# updates when the pool is already at full size, so it is safe to run
	# unconditionally.
	# shellcheck disable=SC2086
	zpool online -e "$pool" $leaves
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

zpool:init:main() {
	set -euxo pipefail
	zpool:init:configure

	local missing=0
	for pool in "${EXPECTED_POOLS[@]}"; do
		if ! zpool:is_imported "$pool"; then
			: "[zpool-init][ERROR] expected pool not imported: $pool (ordering bug? zfs-import-${pool}.service should have run first)"
			missing=1
			continue
		fi
		zpool:expand "$pool"
	done

	if [ "$missing" -ne 0 ]; then
		: "[zpool-init][ERROR] one or more ZFS pools missing at zpool-init time"
		exit 1
	fi

	# Reconcile ZFS mountpoint properties (idempotent)
	: "[zpool-init][INFO] reconciling ZFS mountpoint properties"
	if zpool:is_imported tank; then
		zpool:zfs:set_legacy_mountpoints_for_rke2_paths
		zpool:zfs:reconcile_nerd_mountpoints
	fi

	: "[zpool-init][INFO] ZFS pool expansion and mountpoint reconcile complete"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
	zpool:init:configure
	: "[zpool-init][INFO] sourced mode; helper functions loaded"
else
	ndh::logger:command:run "nixos.zfs.zpool-init" zpool:init:main "$@"
fi
