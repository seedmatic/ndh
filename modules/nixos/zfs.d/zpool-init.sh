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
#   2. Create any disko-declared dataset that is absent, applying its
#      declared ZFS properties at creation.  disko only lays datasets down
#      at install time, so a subtree added to the config after the pool was
#      provisioned (e.g. rke2lab's dataplan on a running host) would never
#      materialise without this create-if-absent pass.
#   3. Reconcile ZFS dataset mountpoint properties for the explicit
#      tank/nerd paths.

zpool:init:configure() {
	# EXPECTED_POOLS + MOUNTPOINTS_TABLE + DATASETS_TABLE are injected by
	# zfs.nix's zpoolInitText wrapper, which builds them from the disko config
	# (`config.disko.devices.zpool`, each dataset's `mountpoint`, and the full
	# dataset inventory with declared ZFS properties).  Fall back to the
	# historical hard-coded values only when the env is missing, so direct
	# `/bin/zpool-init` invocations (e.g. rescue shell) still work.
	if [ -n "${NDH_ZPOOL_INIT_POOLS:-}" ]; then
		# shellcheck disable=SC2206
		EXPECTED_POOLS=(${NDH_ZPOOL_INIT_POOLS})
	else
		EXPECTED_POOLS=(tank recover)
	fi
	MOUNTPOINTS_TABLE="${NDH_ZPOOL_INIT_MOUNTPOINTS:-}"
	DATASETS_TABLE="${NDH_ZPOOL_INIT_DATASETS:-}"
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

zpool:zfs:ensure_datasets() {
	# Create every disko-declared dataset that is absent, applying its declared
	# ZFS properties at creation (mountpoint=legacy on the CSI/guest-owned leaves,
	# canmount=noauto, …).  Driven by DATASETS_TABLE — one
	# "<dataset><TAB><k=v> <k=v> …" line per dataset, injected from the disko
	# config by zfs.nix.  Idempotent: an already-present dataset is left untouched
	# (property drift on existing datasets is not this pass's concern — a fresh
	# subtree is born correct, and there is no every-boot force to migrate).
	local dataset props kv
	[ -n "${DATASETS_TABLE:-}" ] || return 0

	while IFS=$'\t' read -r dataset props; do
		[ -n "$dataset" ] || continue
		zfs list -H -o name "$dataset" >/dev/null 2>&1 && continue

		local -a create_args=()
		for kv in $props; do
			create_args+=(-o "$kv")
		done
		zfs create -p "${create_args[@]}" "$dataset" ||
			: "[zpool-init][WARN] failed to create dataset $dataset"
	done <<<"$DATASETS_TABLE"
}

zpool:zfs:reconcile_nerd_mountpoints() {
	# Drive the reconcile from the MOUNTPOINTS_TABLE env injected by zfs.nix
	# (derived from config.disko.devices.zpool at eval time).  Empty table =
	# nothing to reconcile — supports rescue invocations where disko context
	# is unavailable.
	local dataset
	local desired

	if [ -z "${MOUNTPOINTS_TABLE:-}" ]; then
		: "[zpool-init][INFO] no dataset mountpoint table provided; skipping reconcile"
		return 0
	fi

	while read -r dataset desired; do
		[ -n "$dataset" ] && [ -n "$desired" ] || continue

		if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
			continue
		fi

		if [ "$(zfs get -H -o value mountpoint "$dataset")" != "$desired" ]; then
			zfs set "mountpoint=$desired" "$dataset" || : "[zpool-init][WARN] failed to set mountpoint=$desired on $dataset"
		fi
	done <<< "$MOUNTPOINTS_TABLE"
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
		zpool:zfs:ensure_datasets
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
