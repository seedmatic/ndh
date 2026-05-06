#!/usr/bin/env bash
set -euxo pipefail

# shellcheck source=/dev/null
source @bringupCommonScript@

bringup::ensure_usr_bin_env
bringup::ensure_nixbld_group
bringup::link_legacy_block_devices

mkdir -p /mnt/zfs-root

bringup::udev_block_sync @systemdLibUdevd@

if [[ "@baseImageMode@" == "1" ]]; then
  : '[bringup-zfs] base image mode: skipping disko format, importing existing pools'
else
  "@diskoFormatExe@"

  bringup::udev_block_sync
fi

"@diskoMountExe@"

bringup::udev_block_sync

# ── ZFS install-time throughput tuning ──────────────────────────────────────
# These settings trade durability for speed — safe because these are fresh raw
# disk images written once; real pool config is applied at first boot.
: '[bringup-zfs] tuning ZFS for bulk write throughput'

# sync=disabled: skip ZIL flush on every write — biggest throughput win.
zfs set sync=disabled tank
zfs set sync=disabled recover

# logbias=throughput: avoid indirect ZIL writes for large sequential blocks.
zfs set logbias=throughput tank
zfs set logbias=throughput recover

# Grow ARC to 2/3 of available RAM.  The kernel's default cap is ~1/2 physical
# RAM; raising it lets the guest cache all metadata in RAM for the install phase.
total_kb=$(awk '/MemTotal/ { print $2 }' /proc/meminfo)
arc_max_bytes=$(( total_kb * 2 / 3 * 1024 ))
: '[bringup-zfs] zfs_arc_max → ${arc_max_bytes} bytes (2/3 of ${total_kb} kB)'
echo "${arc_max_bytes}" > /sys/module/zfs/parameters/zfs_arc_max

# ARC min = 1/4 of RAM: prevents the kernel from collapsing the ARC under brief
# memory spikes (e.g. nix-store decompression), avoiding cold-start latency.
arc_min_bytes=$(( total_kb / 4 * 1024 ))
: '[bringup-zfs] zfs_arc_min → ${arc_min_bytes} bytes (1/4 of ${total_kb} kB)'
echo "${arc_min_bytes}" > /sys/module/zfs/parameters/zfs_arc_min

# Disable speculative prefetch.  nixos-install writes sequentially but reads
# metadata in random order — prefetch wastes ARC space and adds CPU overhead.
: '[bringup-zfs] zfs_prefetch_disable → 1 (install is write-dominated)'
echo 1 > /sys/module/zfs/parameters/zfs_prefetch_disable

# Limit dirty data buffer to 20 % of ARC max.  Default is 10 % of physical RAM;
# with sync=disabled and a large ARC, dirty data can accumulate into one giant
# final TXG flush that makes the build appear stuck.  A smaller cap spreads I/O.
dirty_max_bytes=$(( arc_max_bytes / 5 ))
: '[bringup-zfs] zfs_dirty_data_max → ${dirty_max_bytes} bytes (20% of arc_max)'
echo "${dirty_max_bytes}" > /sys/module/zfs/parameters/zfs_dirty_data_max

# txg_timeout=5s (keep default): frequent small flushes spread I/O evenly across
# the install — a longer timeout defers everything into one massive final sync.
: '[bringup-zfs] zfs_txg_timeout → 5s (avoids deferred final flush)'
echo 5 > /sys/module/zfs/parameters/zfs_txg_timeout
# ─────────────────────────────────────────────────────────────────────────────

require_partlabel() {
  local label="$1"
  local dev="/dev/disk/by-partlabel/${label}"
  if [[ ! -b "$dev" ]]; then
    : '[bringup-zfs][ERROR] missing expected partition label: ${label} (${dev})'
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
target_bootstrap_installer="@systemToplevel@/sw/bin/nerd-bringup-install"

mkdir -p "$(dirname "$target_bootstrap_profile")"
if [[ -x "$target_bootstrap_installer" ]]; then
  "$target_bootstrap_installer" "$target_bootstrap_profile"
else
  : "[bringup-zfs][WARN] bootstrap installer missing in target system closure: $target_bootstrap_installer"
fi

: 'Ensure target image store contains the exact system closure referenced'
: 'by boot entries (init=/nix/store/.../init) before nixos-install.'
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

: '[bringup-zfs] post-install zpool status'
zpool status >&2 || true

# ── Post-install inspection pause ────────────────────────────────────────────
# When @pauseAfterInstall@ is set, block here until the operator removes the
# lock file.  Connect to the debug shell and inspect /mnt/zfs-root, then:
#   rm /tmp/xchg/pause.lock
if [[ "@pauseAfterInstall@" == "1" ]]; then
  lock=/tmp/xchg/pause.lock
  touch "$lock"
  echo '[bringup-zfs] *** PAUSED for inspection ***'
  echo '[bringup-zfs]   /mnt/zfs-root is still mounted — inspect freely.'
  echo '[bringup-zfs]   Connect via the debug shell:'
  echo '[bringup-zfs]     sudo socat UNIX-CONNECT:/proc/$(pgrep --newest qemu)/shell.sock -,raw,echo=0,escape=0x1d'
  echo '[bringup-zfs]   When done, resume with:'
  echo '[bringup-zfs]     rm /tmp/xchg/pause.lock'
  inotifywait -q -e delete_self "$lock"
  echo '[bringup-zfs] lock removed — resuming'
fi
# ─────────────────────────────────────────────────────────────────────────────

zpools_file="$(mktemp)"
trap 'rm -f "$zpools_file"' EXIT

# Capture full zpool status as YAML (--json-int avoids scientific notation for byte values).
zpool status --json --json-int | yq -p json -o yaml > "$zpools_file"

env ZPOOLS_FILE="$zpools_file" yq -n \
  '{
    "zpools": load(strenv(ZPOOLS_FILE)),
    "policyNote": @bootSizePolicyNote@
  }' > /tmp/xchg/boot-size-hint.yaml

# ── Reset ZFS install-time tuning before pool export ─────────────────────────
# Drain remaining dirty TXGs first while sync=disabled (no ZIL overhead).
# Without this, restoring sync=standard triggers an uncontrolled final flush.
: '[bringup-zfs] draining dirty TXGs before property reset'
zpool sync tank    || true
zpool sync recover || true

# Restore production pool properties so the exported pool is safe on real hardware.
: '[bringup-zfs] restoring ZFS sync policy before export'
zfs set sync=standard tank    || true
zfs set sync=standard recover || true
zfs set logbias=latency tank   || true
zfs set logbias=latency recover || true
# ─────────────────────────────────────────────────────────────────────────────

"@diskoUnmountExe@"
