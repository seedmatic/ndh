# ndh-ops: run one of the operator's secret-reading tools on a delegation the operator armed before leaving.
#   ndh-ops arm --hours N --tools a,b   the operator only (the sessions are refused it); writes the delegation as root
#   ndh-ops status | disarm             anyone: neither grants anything
#   ndh-ops <tool> [args…]              refused unless an unexpired delegation names <tool>
#   ndh-ops grow <stack> preview|up     the operator's grow: rke2lab's own, by revision (published develop), run from
#                                       the one stack home, the cluster's age identity read here from pass
# The tools are the store paths fixed at build time (tools[]), never a PATH lookup, and every attempt is logged.
# An arming item (items[]) is a permission a tool checks itself in the delegation: arm writes it, nobody runs it.
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

item() { # $1 = a name: whether it is an arming item, matched whole
  local i
  for i in "${items[@]}"; do [[ $i == "$1" ]] && return 0; done
  return 1
}

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
    for t in "${wanted[@]}"; do known "$t" || item "$t" || refuse "arm: $t is not one of: ${!tools[*]} ${items[*]}"; done
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
  grow)
    : "the operator's own invocation, like arm: it reads pass in their shell, and nothing is armed for it"
    (($# == 3)) || { echo "usage: ndh-ops grow <stack> preview|up" >&2; exit 2; }
    stack=$2 action=$3
    [[ $stack =~ ^[a-z][a-z0-9-]*$ ]] || { echo "ndh-ops grow: '$stack' is not a stack name" >&2; exit 2; }
    [[ $action == preview || $action == up ]] || { echo "ndh-ops grow: '$action' is not preview or up" >&2; exit 2; }
    [[ -f $grow_home/Pulumi.yaml ]] || refuse "grow: $grow_home is not the stack home (no Pulumi.yaml)"
    entry="seedmatic/cluster-age/$cluster_age_version"
    : "read once, before nix runs: a pass that cannot show it stops here, and the identity is never printed"
    identity=$(pass show "$entry") || refuse "grow: pass cannot show $entry"
    log "grow: $stack $action (from $grow_home, $grow_flake)"
    status=0
    : "the identity reaches the grow in its environment (RKE2LAB_CLUSTER_AGE), by a prefix assignment: never in argv"
    (cd "$grow_home" && RKE2LAB_CLUSTER_AGE="$identity" nix --refresh run "${grow_flake}#grow" -- "$stack" "$action") ||
      status=$?
    unset identity
    log "grow done: $stack $action exit $status"
    exit "$status"
    ;;
  "" | -h | --help)
    echo "usage: ndh-ops arm --hours N --tools a,b | status | disarm | grow <stack> preview|up | <tool> [args…]   (tools: ${!tools[*]})" >&2
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
