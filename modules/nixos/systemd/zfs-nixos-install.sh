#!/usr/bin/env -S bash -euo pipefail
# shellcheck source=/dev/null
source @nixBashTrampoline@

zfs::obs:enabled() {
  ${NDH_BUILD_OBSERVE:-false}
}

zfs::obs:log() {
  echo "[zfs-nixos-install][obs] $*" >&2
}

# The observer uses a named pipe + a single background writer process:
#   sampler → (JSON line) → FIFO → writer (yq) → YAML stream → xchg/
#
# Benefits vs. in-place yq -i:
#   - O(1) per event: samplers just write one line to the pipe fd, no file I/O
#   - No corruption: the writer is the only process touching the output file
#   - One yq startup at begin, not one per sample
#   - Clean EOF-based shutdown: closing the write-fd drains the writer
#
# Fall back to a local path when xchg is not mounted (standalone runs).
zfs::obs:log_file() {
  if [[ -d /tmp/xchg ]]; then
    echo "/tmp/xchg/zfs-nixos-install-observe.yaml"
  else
    echo "${NDH_BUILD_OBSERVE_LOG:-/var/log/ndh/zfs-nixos-install-observe.yaml}"
  fi
}

# Send one JSON line to the writer via the open pipe fd.
# All callers share the same fd inherited from zfs::obs:start.
zfs::obs:send() {
  [[ -n "${NDH_ZFS_INSTALL_OBS_PIPE_FD:-}" ]] || return 0
  printf '%s\n' "$1" >&"${NDH_ZFS_INSTALL_OBS_PIPE_FD}" 2>/dev/null || true
}

# Emit a phase-marker event.
zfs::obs:mark() {
  zfs::obs:enabled || return 0
  local label="$1" ts
  ts=$(date -Iseconds)
  zfs::obs:send '{"type":"phase","label":"'"$label"'","ts":"'"$ts"'"}'
}

# ── per-metric collectors (return a JSON fragment on stdout) ─────────────────

zfs::obs:sample:arc() {
  local arc="/proc/spl/kstat/zfs/arcstats"
  [[ -r "$arc" ]] || { echo "{}"; return 0; }
  local hits misses evicts size c_max total pct
  hits=$(awk   '$1=="hits"      {print $3}' "$arc" 2>/dev/null || echo 0)
  misses=$(awk '$1=="misses"    {print $3}' "$arc" 2>/dev/null || echo 0)
  evicts=$(awk '$1=="evict_skip"{print $3}' "$arc" 2>/dev/null || echo 0)
  size=$(awk   '$1=="size"      {print $3}' "$arc" 2>/dev/null || echo 0)
  c_max=$(awk  '$1=="c_max"     {print $3}' "$arc" 2>/dev/null || echo 0)
  total=$(( hits + misses ))
  pct=$(( total > 0 ? hits * 100 / total : 0 ))
  printf '{"hits":%s,"misses":%s,"hit_pct":%s,"evict_skip":%s,"size_mb":%s,"c_max_mb":%s}' \
    "$hits" "$misses" "$pct" "$evicts" "$(( size / 1048576 ))" "$(( c_max / 1048576 ))"
}

zfs::obs:sample:zpool() {
  command -v zpool >/dev/null 2>&1 || { echo "[]"; return 0; }
  zpool iostat -Hpp 1 1 2>/dev/null \
    | awk 'NF>=9 && $1!~/-/{
        printf "{\"vdev\":\"%s\",\"ops_r\":%s,\"ops_w\":%s,\"bw_r_kb\":%d,\"bw_w_kb\":%d,\"lat_r_us\":%d,\"lat_w_us\":%d},",
          $1,$4,$5,int($6/1024),int($7/1024),int($8/1000),int($9/1000)
      }' \
    | sed 's/,$//' | awk '{print "["$0"]"}' || echo "[]"
}

zfs::obs:sample:diskio() {
  command -v iostat >/dev/null 2>&1 || { echo "[]"; return 0; }
  iostat -dxz 1 1 2>/dev/null \
    | awk 'NF>=16 && $1!~/Device|^$/{
        printf "{\"dev\":\"%s\",\"r_s\":%s,\"w_s\":%s,\"r_await_ms\":%s,\"w_await_ms\":%s,\"util_pct\":%s},",
          $1,$2,$3,$10,$11,$NF
      }' \
    | sed 's/,$//' | awk '{print "["$0"]"}' || echo "[]"
}

zfs::obs:sample:memory() {
  local dirty wb avail
  dirty=$(awk '$1=="Dirty:"        {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  wb=$(awk    '$1=="Writeback:"    {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  avail=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  printf '{"dirty_kb":%s,"writeback_kb":%s,"avail_mb":%s}' "$dirty" "$wb" "$(( avail / 1024 ))"
}

# Collect all metrics, assemble one JSON line, send to pipe — no yq involved.
zfs::obs:sample() {
  local ts arc zpool diskio mem
  ts=$(date -Iseconds)
  arc="$(zfs::obs:sample:arc)"
  zpool="$(zfs::obs:sample:zpool)"
  diskio="$(zfs::obs:sample:diskio)"
  mem="$(zfs::obs:sample:memory)"
  zfs::obs:send '{"type":"sample","ts":"'"$ts"'","arc":'"$arc"',"zpool":'"$zpool"',"diskio":'"$diskio"',"mem":'"$mem"'}'
}

zfs::obs:start() {
  zfs::obs:enabled || return 0
  local interval="${NDH_BUILD_OBSERVE_INTERVAL:-5}"
  local obs_log_file pipe
  obs_log_file="$(zfs::obs:log_file)"
  mkdir -p "$(dirname "$obs_log_file")"

  # Create the FIFO.
  pipe="$(mktemp -d)/obs.fifo"
  mkfifo "$pipe"
  NDH_ZFS_INSTALL_OBS_PIPE="$pipe"
  export NDH_ZFS_INSTALL_OBS_PIPE

  # Writer: reads one JSON line at a time, converts to a YAML document.
  # Stays alive until write-end is closed (EOF).
  (
    while IFS= read -r line; do
      printf '%s\n---\n' "$line" | @yq@ -p json -o yaml
    done < "$pipe"
  ) >> "$obs_log_file" &
  NDH_ZFS_INSTALL_OBS_WRITER_PID="$!"
  export NDH_ZFS_INSTALL_OBS_WRITER_PID

  # Keep write-end open in this process so the writer doesn't see EOF
  # while the sampler is sleeping between samples.
  exec {NDH_ZFS_INSTALL_OBS_PIPE_FD}>"$pipe"
  export NDH_ZFS_INSTALL_OBS_PIPE_FD

  # Send the header event.
  zfs::obs:send '{"type":"meta","started":"'"$(date -Iseconds)"'"}'

  # Sampler loop — just collects metrics and sends JSON lines to the pipe.
  (
    while true; do
      zfs::obs:sample
      sleep "$interval"
    done
  ) &
  NDH_ZFS_INSTALL_OBS_SAMPLER_PID="$!"
  export NDH_ZFS_INSTALL_OBS_SAMPLER_PID

  zfs::obs:log "writer=${NDH_ZFS_INSTALL_OBS_WRITER_PID} sampler=${NDH_ZFS_INSTALL_OBS_SAMPLER_PID} interval=${interval}s log=${obs_log_file}"
}

zfs::obs:stop() {
  zfs::obs:enabled || return 0
  # Stop sampler first so no new writes arrive while we're draining.
  if [[ -n "${NDH_ZFS_INSTALL_OBS_SAMPLER_PID:-}" ]]; then
    kill "${NDH_ZFS_INSTALL_OBS_SAMPLER_PID}" 2>/dev/null || true
    wait "${NDH_ZFS_INSTALL_OBS_SAMPLER_PID}" 2>/dev/null || true
  fi
  # Send final marker before closing.
  zfs::obs:send '{"type":"meta","stopped":"'"$(date -Iseconds)"'"}'
  # Close write-end → writer sees EOF → flushes remaining documents → exits.
  if [[ -n "${NDH_ZFS_INSTALL_OBS_PIPE_FD:-}" ]]; then
    exec {NDH_ZFS_INSTALL_OBS_PIPE_FD}>&-
  fi
  # Wait for writer to finish flushing to disk before we proceed.
  if [[ -n "${NDH_ZFS_INSTALL_OBS_WRITER_PID:-}" ]]; then
    wait "${NDH_ZFS_INSTALL_OBS_WRITER_PID}" 2>/dev/null || true
  fi
  [[ -n "${NDH_ZFS_INSTALL_OBS_PIPE:-}" ]] && rm -f "${NDH_ZFS_INSTALL_OBS_PIPE}" 2>/dev/null || true
  zfs::obs:log "observer stopped"
}

zfs::guard:mountpoint:check() {
  local install_root_mount_point="$1"
  if ! mountpoint -q "$install_root_mount_point"; then
    : "[zfs-nixos-install][ERROR] expected disko target mountpoint missing: $install_root_mount_point"
    return 1
  fi
  return 0
}

zfs::boot:sync:bringup:to:target() {
  local install_root_mount_point="$1"
  local bringup_boot_source="${BRINGUP_BOOT_MOUNT:-/boot}"
  local target_boot_mount="${install_root_mount_point}/boot"
  local bringup_boot_dev=""
  local target_boot_dev=""

  if ! mountpoint -q "$target_boot_mount"; then
    : "[zfs-nixos-install][ERROR] target boot mountpoint unavailable: $target_boot_mount"
    return 1
  fi

  if ! mountpoint -q "$bringup_boot_source"; then
    : "[zfs-nixos-install][ERROR] bringup boot mountpoint unavailable: $bringup_boot_source"
    return 1
  fi

  bringup_boot_dev="$(findmnt -n -o SOURCE "$bringup_boot_source" 2>/dev/null || true)"
  target_boot_dev="$(findmnt -n -o SOURCE "$target_boot_mount" 2>/dev/null || true)"

  if [[ -n "$bringup_boot_dev" && -n "$target_boot_dev" && "$bringup_boot_dev" == "$target_boot_dev" ]]; then
    : "[zfs-nixos-install] skip boot sync: bringup and target boot mounts are same device ($target_boot_dev)"
    return 0
  fi

  : "[zfs-nixos-install] initializing target boot from bringup mount: src=$bringup_boot_source dst=$target_boot_mount"
  cp -a "$bringup_boot_source/." "$target_boot_mount/"
  sync
}

zfs::boot:sync:target:to:bringup() {
  local install_root_mount_point="$1"
  local bringup_boot_mount="${BRINGUP_BOOT_MOUNT:-/boot}"
  local target_boot_source="${install_root_mount_point}/boot"
  local bringup_boot_dev=""
  local target_boot_dev=""

  if ! mountpoint -q "$target_boot_source"; then
    : "[zfs-nixos-install][ERROR] target boot mountpoint unavailable: $target_boot_source"
    return 1
  fi

  if ! mountpoint -q "$bringup_boot_mount"; then
    : "[zfs-nixos-install][ERROR] bringup boot mountpoint unavailable: $bringup_boot_mount"
    return 1
  fi

  target_boot_dev="$(findmnt -n -o SOURCE "$target_boot_source" 2>/dev/null || true)"
  bringup_boot_dev="$(findmnt -n -o SOURCE "$bringup_boot_mount" 2>/dev/null || true)"

  if [[ -n "$target_boot_dev" && -n "$bringup_boot_dev" && "$target_boot_dev" == "$bringup_boot_dev" ]]; then
    : "[zfs-nixos-install] skip boot sync: target and bringup boot mounts are same device ($target_boot_dev)"
    return 0
  fi

  : "[zfs-nixos-install] syncing target boot back to bringup mount: src=$target_boot_source dst=$bringup_boot_mount"
  cp -a "$target_boot_source/." "$bringup_boot_mount/"
  sync
}

zfs::nixos:install() {
  local install_root_mount_point="@installRootMountPoint@"
  local prebuilt_system_path="${NDH_NIXOS_INSTALL_SYSTEM_PATH:-}"
  local copy_from_store="${NDH_NIXOS_INSTALL_COPY_FROM:-}"

  if [[ -z "$prebuilt_system_path" ]]; then
    : "[zfs-nixos-install][ERROR] NDH_NIXOS_INSTALL_SYSTEM_PATH is not set; prebuilt system path is mandatory"
    return 1
  fi

  zfs::obs:start
  trap 'zfs::obs:stop' EXIT

  zfs::guard:mountpoint:check "$install_root_mount_point"
  zfs::obs:mark "boot-sync-bringup-to-target:start"
  zfs::boot:sync:bringup:to:target "$install_root_mount_point"
  zfs::obs:mark "boot-sync-bringup-to-target:done"

  if [[ -n "$copy_from_store" ]]; then
    zfs::obs:mark "nix-copy-prebuilt:start"
    : "[zfs-nixos-install] copying prebuilt system closure from ${copy_from_store}: ${prebuilt_system_path}"
    nix copy --from "$copy_from_store" "$prebuilt_system_path"
    zfs::obs:mark "nix-copy-prebuilt:done"
  fi

  zfs::obs:mark "nixos-install-prebuilt:start"
  : "[zfs-nixos-install] installing prebuilt system to ${install_root_mount_point}: ${prebuilt_system_path}"
  nixos-install \
    --option accept-flake-config true \
    --option experimental-features "nix-command flakes" \
    --root "$install_root_mount_point" \
    --system "$prebuilt_system_path" \
    --no-root-passwd \
    --no-bootloader \
    --verbose
  zfs::obs:mark "nixos-install-prebuilt:done"

  zfs::obs:mark "boot-sync-target-to-bringup:start"
  zfs::boot:sync:target:to:bringup "$install_root_mount_point"
  zfs::obs:mark "boot-sync-target-to-bringup:done"
  : "[zfs-nixos-install] installation complete; reboot is intentionally disabled"
}

ndh::logger:command:run "nixos.systemd.zfs-nixos-install" zfs::nixos:install "$@"
