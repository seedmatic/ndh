# shellcheck shell=bash disable=SC1091
# bringup-zfs-disk-image buildCommand — observer and QEMU execution
#
# Runs inside nested QEMU as the main build process. Provides:
#   - Debug shell on /dev/hvc0
#   - Builder-side observability (samples QEMU CPU/mem/disk metrics)
#   - Event relay to Vector
#   - Execution of ZFS install script
#
# ENVIRONMENT:
#   NDH_BUILD_OBSERVE                   — Enable build observability
#   NDH_ZFS_INSTALL_OBSERVE             — Enable ZFS install observability (default: 1)
#   NDH_ZFS_INSTALL_OBSERVE_INTERVAL    — Sample interval in seconds (default: 5)
#   NDH_ZFS_INSTALL_PAUSE               — Pause after ZFS install for inspection
#   NDH_VECTOR_ENDPOINT                 — Vector endpoint (baked in: http://10.0.2.2:9001)
#
# SUBSTITUTIONS (from Nix):
#   @tools@                 — Path to tools directory
#   @bash@                  — Path to bash binary
#   @yq@                    — Path to yq-go binary
#   @curl@                  — Path to curl binary
#   @iostat@                — Path to iostat binary
#   @installScript@         — Path to bringup-zfs-disk-images-install script

set -eo pipefail

PS4='[@nixosName@:bringup-vm:${LINENO}] '
set -x
export PATH=@tools@:$PATH

# Export observability variables so they're available in the debug shell
export NDH_BUILD_OBSERVE="${NDH_BUILD_OBSERVE:-}"
export NDH_ZFS_INSTALL_OBSERVE="${NDH_ZFS_INSTALL_OBSERVE:-1}"
export NDH_ZFS_INSTALL_OBSERVE_INTERVAL="${NDH_ZFS_INSTALL_OBSERVE_INTERVAL:-5}"
export NDH_ZFS_INSTALL_PAUSE="${NDH_ZFS_INSTALL_PAUSE:-}"

: 'shell.sock → /dev/hvc0 (first virtio-serial port we add).'
: 'Use hvc0 directly — the /dev/virtio-ports/ symlink needs udev'
: 'and may not exist yet; hvc0 is created by the kernel in devtmpfs.'
: '-i: interactive (job control + prompt); skip -l to avoid /etc/profile.'
while [[ ! -c /dev/hvc0 ]]; do sleep 0.1; done
setsid --ctty @bash@ -i 0<>/dev/hvc0 1>&0 2>&0 &

# ── builder-side observer ─────────────────────────────────────────────────────
# Collects metrics from the linux-builder during the nested QEMU build.
# Events are sent to Vector via obs::vector:push() for real-time aggregation.

obs::enabled() {
  [[ "${NDH_ZFS_INSTALL_OBSERVE:-1}" == "1" ]]
}

obs::sample() {
  local ts qemu_pid qemu_cpu qemu_rss dirty wb avail diskio
  ts=$(date -Iseconds)

  # QEMU process stats (CPU%, RSS in MB)
  qemu_pid=$(pgrep -n qemu 2>/dev/null || echo "")
  if [[ -n "$qemu_pid" ]]; then
    read -r qemu_cpu qemu_rss < <(
      ps -p "$qemu_pid" -o %cpu=,rss= 2>/dev/null \
        | awk '{printf "%s %d", $1, int($2/1024)}'
    )
  else
    qemu_cpu="0" qemu_rss="0"
  fi

  # Host memory pressure
  dirty=$(awk '$1=="Dirty:"        {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  wb=$(awk    '$1=="Writeback:"    {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  avail=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo 2>/dev/null || echo 0)

  # Per-disk I/O on the build device (virtio or loop backing the .raw files)
  diskio=$(@iostat@ -dxz 1 1 2>/dev/null \
    | awk 'NF>=16 && $1!~/Device|^$/{
        printf "{\"dev\":\"%s\",\"r_s\":%s,\"w_s\":%s,\"w_await_ms\":%s,\"util_pct\":%s},",
          $1,$2,$3,$11,$NF
      }' \
    | sed 's/,$//' | awk '{print "["$0"]"}')
  [[ -n "$diskio" ]] || diskio="[]"

  # Output JSON directly (no YAML conversion needed)
  @yq@ -p yaml -o json -I0 - <<EOJ
type: builder-sample
source_layer: builder
ts: "${ts}"
qemu:
  pid: "${qemu_pid:-}"
  cpu_pct: ${qemu_cpu:-0}
  rss_mb: ${qemu_rss:-0}
mem:
  dirty_kb: ${dirty}
  writeback_kb: ${wb}
  avail_mb: $(( avail / 1024 ))
diskio: ${diskio}
EOJ
}

obs::mark() {
  obs::enabled || return 0
  local label="$1"
  obs::vector:push "$(@yq@ -p yaml -o json -I0 - <<EOJ
type: builder-phase
source_layer: builder
label: "${label}"
ts: "$(date -Iseconds)"
EOJ
)"
}

# Push a JSON event to Vector on the VZ host.
# NDH_VECTOR_ENDPOINT injected via --impure-env; fallback to hardcoded default for testing.
obs::vector:push() {
  local endpoint="${NDH_VECTOR_ENDPOINT:-http://10.0.2.2:9001}"
  @curl@ -sf -X POST "${endpoint}" \
    -H "Content-Type: application/json" \
    -d "$1" 2>/dev/null || true
}

obs::start() {
  obs::enabled || return 0
  local interval="${NDH_ZFS_INSTALL_OBSERVE_INTERVAL:-5}"

  # Send header
  obs::vector:push '{"type":"builder-meta","started":"'"$(date -Iseconds)"'"}'

  # Sampler loop
  ( set +x
    while true; do
      obs::vector:push "$(obs::sample)"
      sleep "$interval"
    done ) &
  OBS_SAMPLER_PID="$!"
  export OBS_SAMPLER_PID
}

obs::stop() {
  obs::enabled || return 0
  [[ -n "${OBS_SAMPLER_PID:-}" ]] && \
    kill "${OBS_SAMPLER_PID}" 2>/dev/null || true
  obs::mark "builder-stop"
}

obs::start
trap 'obs::stop' EXIT
obs::mark "qemu-start"

: 'execute the ZFS bringup install script, which formats the disks and installs NixOS onto them'
@bash@ @installScript@

obs::mark "qemu-done"
