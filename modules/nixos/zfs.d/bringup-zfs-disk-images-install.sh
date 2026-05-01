#!/usr/bin/env bash
set -euxo pipefail

# shellcheck source=/dev/null
source @bringupCommonScript@

bringup::ensure_usr_bin_env
bringup::ensure_nixbld_group
bringup::link_legacy_block_devices

mkdir -p /mnt/zfs-root

bringup::udev_block_sync @systemdLibUdevd@

"@diskoFormatExe@"

bringup::udev_block_sync

"@diskoMountExe@"

bringup::udev_block_sync

# ── ZFS install-time throughput tuning ──────────────────────────────────────
# These settings trade durability for speed — safe because these are fresh raw
# disk images written once; real pool config is applied at first boot.
echo "[bringup-zfs][INFO] tuning ZFS for bulk write throughput" >&2

# sync=disabled: skip ZIL flush on every write — biggest throughput win.
zfs set sync=disabled tank
zfs set sync=disabled recover

# logbias=throughput: avoid indirect ZIL writes for large sequential blocks.
zfs set logbias=throughput tank
zfs set logbias=throughput recover

# Grow ARC to 2/3 of available RAM (kernel default cap is ~1/2 physical RAM).
total_kb=$(awk '/MemTotal/ { print $2 }' /proc/meminfo)
arc_max_bytes=$(( total_kb * 2 / 3 * 1024 ))
echo "[bringup-zfs][INFO] zfs_arc_max → ${arc_max_bytes} bytes (2/3 of ${total_kb} kB)" >&2
echo "${arc_max_bytes}" > /sys/module/zfs/parameters/zfs_arc_max

# txg_timeout=5s (keep default): with sync=disabled already eliminating per-write
# ZIL latency, extending the timeout only defers dirty data into a massive final
# flush at unmount time — txg_sync dominates iotop and the install appears stuck.
# Frequent small flushes (5s) spread the I/O evenly across the install duration.
echo "[bringup-zfs][INFO] zfs_txg_timeout → 5s (default, avoids deferred final flush)" >&2
echo 5 > /sys/module/zfs/parameters/zfs_txg_timeout
# ─────────────────────────────────────────────────────────────────────────────

require_partlabel() {
  local label="$1"
  local dev="/dev/disk/by-partlabel/${label}"
  if [[ ! -b "$dev" ]]; then
    echo "[bringup-zfs][ERROR] missing expected partition label: ${label} (${dev})" >&2
    lsblk -a -f >&2 || true
    return 1
  fi
}

# Enforce canonical expected partition labels from disko layout.
require_partlabel esp-boot
require_partlabel esp-tank1
require_partlabel esp-tank2
require_partlabel esp-tank3
require_partlabel esp-recover
require_partlabel tank1
require_partlabel tank2
require_partlabel tank3
require_partlabel recover

nix-store --option build-users-group "" --load-db < @closureRegistration@

target_bootstrap_profile="/mnt/zfs-root/nix/var/nix/profiles/per-user/root/io-nxmatic-nix-darwin-home-bringup-runtime"
target_bootstrap_installer="@systemToplevel@/sw/bin/nerd-nixos-bringup-install"

mkdir -p "$(dirname "$target_bootstrap_profile")"
if [[ -x "$target_bootstrap_installer" ]]; then
  "$target_bootstrap_installer" "$target_bootstrap_profile"
else
  echo "[bringup-zfs][WARN] bootstrap installer missing in target system closure: $target_bootstrap_installer" >&2
fi

: "Ensure target image store contains the exact system closure referenced"
: "by boot entries (init=/nix/store/.../init) before nixos-install."
bringup::ensure_toplevel_in_target_store "/mnt/zfs-root" @systemToplevel@

channel_arg='@channelFlag@'
if [[ -n "$channel_arg" ]]; then
  @nixosInstall@ \
    --root /mnt/zfs-root \
    --no-root-passwd \
    --system @systemToplevel@ \
    --substituters "" \
    $channel_arg
else
  @nixosInstall@ \
    --root /mnt/zfs-root \
    --no-root-passwd \
    --system @systemToplevel@ \
    --substituters ""
fi

: "[bringup-zfs][INFO] post-install zpool capacity summary" >&2
zpool iostat -vH -p >&2 || true

zfs_pools_file="$(mktemp)"
zpool_iostat_file="$(mktemp)"
trap 'rm -f "$zfs_pools_file" "$zpool_iostat_file"' EXIT

yq -n '[]' > "$zfs_pools_file"
zpool iostat -vH -p > "$zpool_iostat_file"

zpool list -H -o name | while IFS= read -r pool_name; do
  [[ -z "$pool_name" ]] && continue

  pool_row="$(awk -v p="$pool_name" '$1 == p { print; exit }' "$zpool_iostat_file")"
  [[ -z "$pool_row" ]] && continue

  alloc_bytes="$(awk '{print $2}' <<<"$pool_row")"
  free_bytes="$(awk '{print $3}' <<<"$pool_row")"

  size_bytes=$(( alloc_bytes + free_bytes ))
  size_mb=$(( (size_bytes + 999999) / 1000000 ))
  alloc_mb=$(( (alloc_bytes + 999999) / 1000000 ))
  free_mb=$(( (free_bytes + 999999) / 1000000 ))

  if [[ "$size_bytes" -gt 0 ]]; then
    capacity_percent=$(( (alloc_bytes * 100) / size_bytes ))
  else
    capacity_percent=0
  fi

  env \
    POOL_NAME="$pool_name" \
    SIZE_MB="$size_mb" \
    ALLOC_MB="$alloc_mb" \
    FREE_MB="$free_mb" \
    CAPACITY_PERCENT="$capacity_percent" \
    yq -i '
      . += [{
        "name": strenv(POOL_NAME),
        "sizeMB": (strenv(SIZE_MB) | tonumber),
        "allocMB": (strenv(ALLOC_MB) | tonumber),
        "freeMB": (strenv(FREE_MB) | tonumber),
        "capacityPercent": (strenv(CAPACITY_PERCENT) | tonumber)
      }]
    ' "$zfs_pools_file"
done

env ZFS_POOLS_FILE="$zfs_pools_file" yq -n \
  '{
	"zfsPools": load(strenv(ZFS_POOLS_FILE)),
    "policyNote": @bootSizePolicyNote@
  }' > boot-size-hint.yaml

# ── Reset ZFS install-time tuning before pool export ─────────────────────────
# Drain remaining dirty TXGs first while sync=disabled (no ZIL overhead).
# Without this, restoring sync=standard triggers an uncontrolled final flush.
echo "[bringup-zfs][INFO] draining dirty TXGs before property reset" >&2
zfs sync tank    || true
zfs sync recover || true

# Restore production pool properties so the exported pool is safe on real hardware.
echo "[bringup-zfs][INFO] restoring ZFS sync policy before export" >&2
zfs set sync=standard tank    || true
zfs set sync=standard recover || true
zfs set logbias=latency tank   || true
zfs set logbias=latency recover || true
# ─────────────────────────────────────────────────────────────────────────────

"@diskoUnmountExe@"
