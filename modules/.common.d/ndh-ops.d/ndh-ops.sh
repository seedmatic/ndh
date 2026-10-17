# ndh-ops: run one of the operator's secret-reading tools on a delegation the operator armed before leaving.
#   ndh-ops arm --hours N --tools a,b   the operator only (the sessions are refused it); writes the delegation as root
#   ndh-ops status | disarm             anyone: neither grants anything
#   ndh-ops <tool> [args…]              refused unless an unexpired delegation names <tool>
# The tools are the store paths fixed at build time (tools[]), never a PATH lookup, and every attempt is logged.
set -euo pipefail

delegation="$dir/delegation"
log_file="${XDG_STATE_HOME:-$HOME/.local/state}/ndh-ops/log"

log() {
  mkdir -p "$(dirname "$log_file")"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$log_file"
  logger -t ndh-ops "$*" 2>/dev/null || true
}

refuse() {
  echo "ndh-ops: refused: $*" >&2
  log "refused: $*"
  exit 3
}

known() { [[ -n ${tools[$1]:-} ]]; }

field() { sed -n "s/^$1=//p" "$delegation"; }

armed() { # an unexpired delegation; a missing or malformed expiry counts as none
  local expires
  [[ -r $delegation ]] || return 1
  expires=$(field expires)
  [[ $expires =~ ^[0-9]+$ ]] && (($(date +%s) < expires))
}

valid_for() { # $1 = tool
  armed && [[ ",$(field tools)," == *",$1,"* ]]
}

case ${1:-} in
  arm)
    shift
    hours="" list=""
    while (($#)); do
      case $1 in
        --hours) hours=${2:-}; shift ;;
        --tools) list=${2:-}; shift ;;
        *) refuse "arm: unknown argument $1" ;;
      esac
      shift
    done
    if ! [[ $hours =~ ^[0-9]+$ ]] || ((hours < 1 || hours > max_hours)); then
      refuse "arm: --hours must be 1..$max_hours"
    fi
    [[ -n $list ]] || refuse "arm: --tools is required"
    IFS=, read -ra wanted <<<"$list"
    for t in "${wanted[@]}"; do known "$t" || refuse "arm: $t is not one of: ${!tools[*]}"; done
    expires=$(($(date +%s) + hours * 3600))
    body="tools=$list
expires=$expires
armed_by=$(id -un)
armed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    $sudo install -d -m 0755 "$dir"
    printf '%s\n' "$body" | $sudo tee "$delegation.new" >/dev/null
    $sudo chmod 0644 "$delegation.new"
    $sudo mv "$delegation.new" "$delegation"
    log "armed: tools=$list for ${hours}h"
    echo "ndh-ops: armed for $list until $(date -r "$expires" 2>/dev/null || date -d "@$expires")"
    ;;
  disarm)
    $sudo rm -f "$delegation"
    log "disarmed"
    echo "ndh-ops: disarmed"
    ;;
  status)
    if armed; then
      echo "armed: $(field tools), until $(date -r "$(field expires)" 2>/dev/null || date -d "@$(field expires)"), by $(field armed_by)"
    else
      echo "not armed"
    fi
    ;;
  "" | -h | --help)
    echo "usage: ndh-ops arm --hours N --tools a,b | status | disarm | <tool> [args…]   (tools: ${!tools[*]})" >&2
    exit 2
    ;;
  *)
    tool=$1
    shift
    known "$tool" || refuse "$tool is not an operator tool (${!tools[*]})"
    valid_for "$tool" || refuse "no unexpired delegation names $tool"
    log "run: $tool $* (cwd $PWD)"
    status=0
    "${tools[$tool]}" "$@" || status=$?
    log "done: $tool exit $status"
    exit "$status"
    ;;
esac
