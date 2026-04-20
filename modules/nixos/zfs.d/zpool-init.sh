#!/usr/bin/env bash
# provision-disk-zfs-datastore: prepare disk layout and ZFS datastore inside guest
# - Runs disko (format+mount), converts ZFS mountpoints to legacy, ensures pools are imported
# - System bootloader/switch/rebuild is handled remotely by host workflow

set -euxo pipefail

DISKO_NIX="${DISKO_NIX:-${DISKO_NIX_DEFAULT:-/etc/nixos/disko.nix}}"
PRIMARY_POOL="tank"
EXPECTED_POOLS=(tank recover)

import_pool_if_discoverable() {
  local pool="$1"
  if pool_discoverable "$pool"; then
    zpool import -N "$pool" >/dev/null 2>&1 || true
  fi
}

set_legacy_mountpoints_for_explicit_paths() {
  local pool="$1"

  zfs list -H -o name,mountpoint -r "$pool" 2>/dev/null | while read -r dataset mountpoint; do
    case "$mountpoint" in
      legacy | none | -)
        continue
        ;;
      /tank* | /recover*)
        # Keep inherited pool-internal topology mountpoints unchanged.
        continue
        ;;
      /*)
        zfs set mountpoint=legacy "$dataset" || : "→ WARN: failed to set legacy on $dataset"
        ;;
    esac
  done
}

pool_imported() {
  local pool="$1"
  zpool list -H -o name "$pool" >/dev/null 2>&1
}

pool_discoverable() {
  local pool="$1"
  zpool import 2>/dev/null | awk -v pool="$pool" '$1 == "pool:" && $2 == pool { found = 1 } END { exit(found ? 0 : 1) }'
}

if pool_imported "$PRIMARY_POOL"; then
  : "→ primary pool already imported (${PRIMARY_POOL}), skipping provisioning"
elif pool_discoverable "$PRIMARY_POOL"; then
  : "→ primary pool discoverable (${PRIMARY_POOL}), importing readonly-style (-N) for normalization"
  for pool in "${EXPECTED_POOLS[@]}"; do
    import_pool_if_discoverable "$pool"
  done
else
  : "→ running disko configuration"
  if [ -f "${DISKO_NIX}" ]; then
    disko --mode format,mount "${DISKO_NIX}"
  else
    : "→ ERROR: disko.nix not found at expected path"
    exit 1
  fi

  : "→ unmounting ZFS datasets for expected pools"
  for pool in "${EXPECTED_POOLS[@]}"; do
    zfs list -H -o name -r "$pool" 2>/dev/null | while read -r dataset; do
      zfs unmount "$dataset" 2>/dev/null || true
    done
  done
fi

: "→ normalizing ZFS mountpoint=legacy for explicit path datasets"
for pool in "${EXPECTED_POOLS[@]}"; do
  if zpool list -H -o name "$pool" >/dev/null 2>&1; then
    set_legacy_mountpoints_for_explicit_paths "$pool"
  fi
done

: "→ ensuring expected ZFS pools are imported"
for pool in "${EXPECTED_POOLS[@]}"; do
  if pool_imported "$pool"; then
    continue
  fi

  import_pool_if_discoverable "$pool"

  if ! pool_imported "$pool"; then
    : "→ WARNING: expected pool not imported: $pool"
  fi
done

: "→ datastore provisioning complete"
