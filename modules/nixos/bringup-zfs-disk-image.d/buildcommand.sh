# shellcheck shell=bash disable=SC1091
# bringup-zfs-disk-image buildCommand — observer and QEMU execution
#
# Runs inside nested QEMU as the main build process. Provides:
#   - Debug shell on /dev/hvc0
#   - Builder-side observability (samples QEMU CPU/mem/disk metrics)
#   - Event relay to Vector
#   - Execution of ZFS install script
#
# ENVIRONMENT (exported for debug shell):
#   NDH_BUILD_OBSERVE                   - Enable build observability (master gate)
#   NDH_BUILD_OBSERVE_INTERVAL          - Sample interval in seconds
#   NDH_BUILD_OBSERVE_SESSION           - Session id (injected via --impure-env)
#   NDH_BUILD_OBSERVE_HOST              - Short host label   (injected via --impure-env)
#   NDH_VECTOR_ENDPOINT                 - Vector endpoint (baked in: http://10.0.2.2:9001)
#   NDH_NIXOS_NAME                      - Short hostname label for PS4 logging
#   NDH_INSTALL_SCRIPT                  - Path to bringup-zfs-disk-images-install script

set -eo pipefail

PS4="[${NDH_NIXOS_NAME:-nixos}:bringup-vm:\${LINENO}] "
set -x

# Export observability variables (available in debug shell).
# NDH_BUILD_OBSERVE is the master gate; default off so samples only flow
# when the operator explicitly opts in (via nix-build-observe or NDH_BUILD_OBSERVE=true).
export NDH_BUILD_OBSERVE="${NDH_BUILD_OBSERVE:-false}"
export NDH_BUILD_OBSERVE_INTERVAL="${NDH_BUILD_OBSERVE_INTERVAL:-5}"
# Session identity injected via --impure-env by nix-build-observe.
# The aggregator's require_session filter drops events without these fields.
export NDH_BUILD_OBSERVE_SESSION="${NDH_BUILD_OBSERVE_SESSION:-}"
export NDH_BUILD_OBSERVE_HOST="${NDH_BUILD_OBSERVE_HOST:-}"

: 'shell.sock -> /dev/hvc0 (first virtio-serial port we add).'
: 'Use hvc0 directly - the /dev/virtio-ports/ symlink needs udev'
: 'and may not exist yet; hvc0 is created by the kernel in devtmpfs.'
: '-i: interactive (job control + prompt); skip -l to avoid /etc/profile.'
: 'NDH_INTERACTIVE_BASH points at bashInteractive so readline (history + '
: 'line editing) works over the socat connection; the plain `bash` in PATH '
: 'is the minimal non-interactive build and gives a raw, unusable prompt.'
while [[ ! -c /dev/hvc0 ]]; do sleep 0.1; done
setsid --ctty "${NDH_INTERACTIVE_BASH:-bash}" -i 0<>/dev/hvc0 1>&0 2>&0 &

# -- builder-side observer --
# Collects metrics from the linux-builder during the nested QEMU build.
# Events are sent to Vector via obs::vector:push() for real-time aggregation.

obs::enabled() {
  ${NDH_BUILD_OBSERVE:-false}
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
  diskio=$(iostat -dxz 1 1 2>/dev/null \
    | awk 'NF>=16 && $1!~/Device|^$/{
        printf "{\"dev\":\"%s\",\"r_s\":%s,\"w_s\":%s,\"w_await_ms\":%s,\"util_pct\":%s},",
          $1,$2,$3,$11,$NF
      }' \
    | sed 's/,$//' | awk '{print "["$0"]"}')
  [[ -n "$diskio" ]] || diskio="[]"

  # Output JSON directly (no YAML conversion needed)
  yq -p yaml -o json -I0 - <<EOJ
type: builder-sample
source_layer: builder
ts: "${ts}"
session: "${NDH_BUILD_OBSERVE_SESSION}"
host: "${NDH_BUILD_OBSERVE_HOST}"
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
  obs::vector:push "$(yq -p yaml -o json -I0 - <<EOJ
type: builder-phase
source_layer: builder
label: "${label}"
ts: "$(date -Iseconds)"
session: "${NDH_BUILD_OBSERVE_SESSION}"
host: "${NDH_BUILD_OBSERVE_HOST}"
EOJ
)"
}

# Push a JSON event to Vector on the VZ host.
# NDH_VECTOR_ENDPOINT injected via --impure-env; fallback to hardcoded default for testing.
obs::vector:push() {
  local endpoint="${NDH_VECTOR_ENDPOINT:-http://10.0.2.2:9001}"
  curl -sf -X POST "${endpoint}" \
    -H "Content-Type: application/json" \
    -d "$1" 2>/dev/null || true
}

obs::start() {
  obs::enabled || return 0
  local interval="${NDH_BUILD_OBSERVE_INTERVAL:-5}"

  # Relay: forward local 9001 → NDH_VECTOR_RELAY_TARGET (macOS Vector).
  # The nested QEMU uses SLIRP; 10.0.2.2 is this linux-builder host.
  # Start socat only when a relay target is configured.
  if [[ -n "${NDH_VECTOR_RELAY_TARGET:-}" ]] && command -v socat >/dev/null 2>&1; then
    socat TCP-LISTEN:9001,fork,reuseaddr TCP:"${NDH_VECTOR_RELAY_TARGET}" &
    _NDH_VECTOR_RELAY_PID="$!"
    export _NDH_VECTOR_RELAY_PID
  fi

  # Send header
  obs::vector:push "$(yq -p yaml -o json -I0 - <<EOJ
type: builder-meta
source_layer: builder
started: "$(date -Iseconds)"
session: "${NDH_BUILD_OBSERVE_SESSION}"
host: "${NDH_BUILD_OBSERVE_HOST}"
EOJ
)"

  # Sampler loop — set +e so a transient metric failure never kills the loop.
  ( set +x +e
    while true; do
      obs::vector:push "$(obs::sample)" || true
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
  [[ -n "${_NDH_VECTOR_RELAY_PID:-}" ]] && \
    kill "${_NDH_VECTOR_RELAY_PID}" 2>/dev/null || true
}

obs::start
trap 'obs::stop' EXIT
obs::mark "qemu-start"

: 'execute the ZFS bringup install script, which formats the disks and installs NixOS onto them'
bash "${NDH_INSTALL_SCRIPT}"

obs::mark "qemu-done"
