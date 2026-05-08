# shellcheck shell=bash disable=SC1091
# nix-build-observe — wrap any `nix build` with multi-layer observability.
#
# Collects metrics from three layers during a NixOS disk-image bringup build:
#   macOS VZ host   — real-time (vm_stat, iostat, nix-daemon cpu/rss)
#   linux-builder   — real-time event forwarding via Vector agent
#   QEMU guest      — real-time event forwarding via nested Vector relay
#
# Requires: vector, yq-go (provided via bootstrap runtime profile)
#
# USAGE:
#   nix run .#nix-build-observe -- .#nixosDiskImages.bioskop -L
#   env NDH_ZFS_INSTALL_OBSERVE=true NDH_BRINGUP_PAUSE=true nix run .#nix-build-observe -- .#nixosDiskImages.bioskop -L
#
# ENVIRONMENT:
#   NDH_BUILD_OBSERVE_INTERVAL=5    — macOS sample interval in seconds (default: 5)
#   NDH_BUILD_OBSERVE_DIR           — output dir (default: .local.d relative to CWD)
#   NDH_VECTOR_HTTP_PORT=9001       — Vector HTTP source port (default: 9001)
#   NDH_VECTOR_API_PORT=8686        — Vector API/health port (default: 8686)
#
# Build environment (passed through to nested builds):
#   NDH_BRINGUP_PAUSE               — "true" to pause after ZFS install for inspection
#   NDH_ZFS_INSTALL_OBSERVE         — "false" to disable detailed ZFS install observation (default: true)
#
# OUTPUT:
#   .local.d/<iso8601>-<attr>.ndjson   — NDJSON stream, one JSON event per line
#   .local.d/latest.ndjson             — symlink to most recent

# Load bash trampoline (Nix profile + re-exec under Nix bash if needed)
source "${NDH_NIX_BASH_TRAMPOLINE}"

set -euo pipefail

# ── globals (defaults; functions fill in the rest) ────────────────────────────
OBS_TMPDIR=""
OBS_ATTR=""
OBS_SAFE_ATTR=""
OBS_HOST=""
OBS_SESSION=""
OBS_DIR="${NDH_BUILD_OBSERVE_DIR:-.local.d}"
OBS_OUT_FILE=""
OBS_HTTP_PORT="${NDH_VECTOR_HTTP_PORT:-9001}"
OBS_API_PORT="${NDH_VECTOR_API_PORT:-8686}"
OBS_VECTOR_PID=""
OBS_SAMPLER_PID=""
_OBS_CLEANUP_DONE=0

# ── shared helpers ────────────────────────────────────────────────────────────

# Extract the flake attribute from the argument list.
# Looks for the first arg containing '#' and returns everything after it.
# Example: .#nixosDiskImages.bioskop  →  nixosDiskImages.bioskop
obs::attr:parse() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == *\#* ]]; then
      printf '%s' "${arg##*#}"
      return
    fi
  done
  printf '%s' "unknown"
}

vz::pagesize() { pagesize 2>/dev/null || sysctl -n hw.pagesize 2>/dev/null || echo 16384; }

vz::sample() {
  local ts page_size pages_free pages_wired pages_compressed
  ts=$(date -Iseconds)
  page_size=$(vz::pagesize)

  eval "$(vm_stat 2>/dev/null | awk '
    /Pages free:/                        {gsub(/\./,"",$NF); printf "pages_free=%s\n",       $NF}
    /Pages wired down:/                  {gsub(/\./,"",$NF); printf "pages_wired=%s\n",      $NF}
    /Pages occupied.*compressor:/        {gsub(/\./,"",$NF); printf "pages_compressed=%s\n", $NF}
  ')"
  local free_mb=$(( (${pages_free:-0}       * page_size) / 1048576 ))
  local wired_mb=$(( (${pages_wired:-0}     * page_size) / 1048576 ))
  local comp_mb=$(( (${pages_compressed:-0} * page_size) / 1048576 ))

  local diskio
  diskio=$(iostat -d -K 2>/dev/null \
    | awk 'NR>2 && $1!="" {
        printf "{\"dev\":\"%s\",\"kb_per_t\":%s,\"tps\":%s,\"mb_s\":%s},",
          $1, $2, $3, $4
      }' \
    | sed 's/,$//' | awk '{print "["$0"]"}')
  [[ -n "$diskio" ]] || diskio="[]"

  local nix_pid nix_cpu nix_rss
  # On macOS the daemon COMM is truncated to "nix"; use launchctl to get the authoritative PID.
  nix_pid=$(launchctl print system/org.nixos.nix-daemon 2>/dev/null \
              | awk '/^\s*pid\s*=/ {print $3; exit}') \
    || nix_pid=""
  if [[ -n "$nix_pid" ]]; then
    read -r nix_cpu nix_rss < <(
      ps -p "$nix_pid" -o %cpu=,rss= 2>/dev/null \
        | awk '{printf "%s %d", $1, int($2/1024)}'
    ) 2>/dev/null || { nix_cpu="0"; nix_rss="0"; }
  else
    nix_cpu="0"; nix_rss="0"
  fi

  yq -p yaml -o json - <<EOF
type: vz-sample
source_layer: vz-host
ts: "${ts}"
mem:
  free_mb: ${free_mb}
  wired_mb: ${wired_mb}
  compressed_mb: ${comp_mb}
diskio: ${diskio}
nix:
  pid: "${nix_pid:-}"
  cpu_pct: ${nix_cpu:-0}
  rss_mb: ${nix_rss:-0}
host: "${OBS_HOST}"
session: "${OBS_SESSION}"
EOF
}

vz::phase() {
  yq -p yaml -o json - <<EOF
type: vz-phase
source_layer: vz-host
label: "${1}"
ts: "$(date -Iseconds)"
host: "${OBS_HOST}"
session: "${OBS_SESSION}"
EOF
}

# ── vector ────────────────────────────────────────────────────────────────────

obs::vector:send() {
  local body="$1"
  local http_code
  http_code=$(printf '%s' "${body}" | curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://127.0.0.1:${OBS_HTTP_PORT}" \
    -H "Content-Type: application/json" \
    -d @- 2>/dev/null) || {
    echo "[nix-build-observe][WARN] Vector curl failed (connection refused?)" >&2
    return 0
  }
  [[ "${http_code}" == "2"* ]] || \
    echo "[nix-build-observe][WARN] Vector HTTP ${http_code} for event: ${body:0:80}..." >&2
}

obs::vector:config() {
  cat <<VCFG
api:
  enabled: true
  address: "127.0.0.1:${OBS_API_PORT}"

sources:
  nix_bld_http:
    type: http_server
    address: "0.0.0.0:${OBS_HTTP_PORT}"
    decoding:
      codec: json
  vector_logs:
    type: internal_logs
  vector_metrics:
    type: internal_metrics

sinks:
  ndjson_file:
    type: file
    inputs: ["nix_bld_http"]
    path: "${OBS_OUT_FILE}"
    encoding:
      codec: json
    buffer:
      type: memory
      max_events: 1
      when_full: block
  vector_stderr:
    type: console
    inputs: ["vector_logs"]
    target: stderr
    encoding:
      codec: text
  vector_metrics_file:
    type: file
    inputs: ["vector_metrics"]
    path: "${OBS_OUT_FILE%.ndjson}.vector-metrics.ndjson"
    encoding:
      codec: json
VCFG
}

obs::vector:start() {
  # If the LaunchAgent Vector is already healthy, reuse it — no lifecycle management needed.
  if curl -sf "http://127.0.0.1:${OBS_API_PORT}/health" &>/dev/null; then
    echo "[nix-build-observe][INFO] using persistent LaunchAgent Vector on port ${OBS_API_PORT}" >&2
    return 0
  fi

  OBS_TMPDIR="$(mktemp -d)"

  obs::vector:config > "${OBS_TMPDIR}/vector.yaml"

  vector --config-yaml "${OBS_TMPDIR}/vector.yaml" \
    --log-format text \
    2>"${OBS_TMPDIR}/vector.log" &
  OBS_VECTOR_PID="$!"

  local retries=30
  while ! curl -sf "http://127.0.0.1:${OBS_API_PORT}/health" &>/dev/null; do
    (( retries-- )) || {
      echo "[nix-build-observe][ERROR] Vector failed to start. Log:" >&2
      cat "${OBS_TMPDIR}/vector.log" >&2
      exit 1
    }
    sleep 0.3
  done
  echo "[nix-build-observe][INFO] Vector ready → ${OBS_OUT_FILE}" >&2
}


obs::start() {
  OBS_HTTP_PORT="${NDH_VECTOR_HTTP_PORT:-9001}"
  OBS_API_PORT="${NDH_VECTOR_API_PORT:-8686}"

  obs::vector:start
  obs::vector:send "$(vz::phase "vz-build-start")"

  local interval="${NDH_BUILD_OBSERVE_INTERVAL:-5}"
  (
    set +x
    while true; do
      obs::vector:send "$(vz::sample)"
      sleep "$interval"
    done
  ) &
  OBS_SAMPLER_PID="$!"
  ln -sf "${OBS_OUT_FILE}" "$(dirname "${OBS_OUT_FILE}")/latest.ndjson"
}

obs::rotate() {
  # Keep only the three most recent session NDJSON files.
  # Session names start with an ISO-8601 UTC timestamp so `sort -r` == newest-first.
  local keep=3
  local -a victims=()
  mapfile -t victims < <(
    find "${OBS_DIR}" -maxdepth 1 -type f -name '[0-9]*.ndjson' 2>/dev/null \
      | sort -r \
      | tail -n +"$((keep + 1))"
  )
  (( ${#victims[@]} == 0 )) && return 0
  rm -f "${victims[@]}"
}

obs::stop() {
  [[ "${_OBS_CLEANUP_DONE}" == "1" ]] && return 0
  _OBS_CLEANUP_DONE=1

  [[ -n "${OBS_SAMPLER_PID:-}" ]] && kill "${OBS_SAMPLER_PID}" 2>/dev/null || true
  obs::vector:send "$(vz::phase "vz-build-done")" || true

  # Only kill Vector if we started it ourselves (LaunchAgent instances are left running).
  [[ -n "${OBS_VECTOR_PID:-}" ]] && kill "${OBS_VECTOR_PID}" 2>/dev/null || true
  [[ -n "${OBS_VECTOR_PID:-}" ]] && wait "${OBS_VECTOR_PID}" 2>/dev/null || true
  [[ -n "${OBS_TMPDIR:-}" ]]     && rm -rf "${OBS_TMPDIR}" || true

  obs::rotate || true

  echo "[nix-build-observe][INFO] observe log: ${OBS_OUT_FILE}" >&2
}

obs::on_signal() {
  local sig="${1:-INT}"
  obs::stop
  # Re-raise so the parent shell sees the correct exit status (128+signum).
  trap - "${sig}"
  kill -"${sig}" "$$"
}

obs::build:run() {
  local -a impure_env_args=()

  # Pass through user-controllable environment variables.
  # Each gate must be "true" or "false" — the flake rejects anything else.
  if [[ -n "${NDH_BRINGUP_PAUSE:-}" ]]; then
    impure_env_args+=(--impure-env "NDH_BRINGUP_PAUSE=${NDH_BRINGUP_PAUSE}")
  fi
  if [[ -n "${NDH_ZFS_INSTALL_OBSERVE:-}" ]]; then
    impure_env_args+=(--impure-env "NDH_ZFS_INSTALL_OBSERVE=${NDH_ZFS_INSTALL_OBSERVE}")
  fi
  if [[ -n "${NDH_ZFS_INSTALL_OBSERVE_INTERVAL:-}" ]]; then
    impure_env_args+=(--impure-env "NDH_ZFS_INSTALL_OBSERVE_INTERVAL=${NDH_ZFS_INSTALL_OBSERVE_INTERVAL}")
  fi
  if [[ -n "${NDH_LINUX_BUILDER_GC_BEFORE_BUILD:-}" ]]; then
    impure_env_args+=(--impure-env "NDH_LINUX_BUILDER_GC_BEFORE_BUILD=${NDH_LINUX_BUILDER_GC_BEFORE_BUILD}")
  fi

  # Always pass these
  impure_env_args+=(--impure-env NDH_BUILD_OBSERVE=1)

  # Propagate the session identity so every layer can tag its own events.
  # Without these the aggregator's require_session filter drops the sample.
  impure_env_args+=(--impure-env "NDH_BUILD_OBSERVE_SESSION=${OBS_SESSION}")
  impure_env_args+=(--impure-env "NDH_BUILD_OBSERVE_HOST=${OBS_HOST}")

  # Pin the endpoint the nested-QEMU guest uses.  10.0.2.2 is the macOS host
  # as seen from linux-builder SLIRP (the builder's Vector agent forwards to
  # the macOS aggregator).  We set it explicitly rather than relying on the
  # hardcoded fallback baked into buildcommand.sh.
  impure_env_args+=(--impure-env "NDH_VECTOR_ENDPOINT=http://10.0.2.2:${OBS_HTTP_PORT}")

  # Tee the nix-daemon JSON stream into Vector so `source_layer=nix-daemon`
  # events land in the aggregator alongside vz-host/builder/guest events.
  # yq -I0 emits one compact JSON object per line (matches Vector's http_server
  # json-lines decoder).  The outer `|| true` preserves tolerance for partial
  # streams when the build is interrupted.
  nix build \
      --extra-experimental-features "nix-command flakes configurable-impure-env" \
      --impure \
      "${impure_env_args[@]}" \
      --out-link result \
      --json "$@" \
    | env OBS_SESSION="${OBS_SESSION}" OBS_HOST="${OBS_HOST}" \
        yq -p json -o json -I0 \
          '. + {"source_layer": "nix-daemon", "session": strenv("OBS_SESSION"), "host": strenv("OBS_HOST")}' \
        2>/dev/null \
    | while IFS= read -r event; do
        [[ -n "${event}" ]] || continue
        obs::vector:send "${event}" || true
      done || true

}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
  OBS_ATTR="$(obs::attr:parse "$@")"
  OBS_SAFE_ATTR="${OBS_ATTR//[^a-zA-Z0-9._-]/_}"
  OBS_HOST="${OBS_ATTR##*.}"                         # last component: bioskop
  OBS_SESSION="$(date -u +%Y%m%dT%H%M%SZ)-$$-${OBS_SAFE_ATTR}"
  OBS_DIR="${NDH_BUILD_OBSERVE_DIR:-.local.d}"
  mkdir -p "${OBS_DIR}"
  OBS_DIR="$(cd "${OBS_DIR}" && pwd -P)"
  OBS_OUT_FILE="${OBS_DIR}/${OBS_SESSION}.ndjson"    # matches Vector {{ session }}.ndjson

  obs::start
  trap 'obs::stop'              EXIT
  trap 'obs::on_signal INT'     INT
  trap 'obs::on_signal TERM'    TERM

  obs::build:run "$@"
}

main "$@"
