# ndh-claude-wake: after a cold restart, reopen every session security engraved, each in its VS Code workspace.
#   ndh-claude-wake [--dry-run] [--only <name>]…
# It never runs `claude`: it asks VS Code, through LaunchServices, to open the engraved workspace and then the
# documented `<scheme>://anthropic.claude-code/open?session=<id>` link, so every session is spawned by VS Code with
# VS Code's own environment (a `claude --resume` from a session's shell inherits CLAUDE_CODE_CHILD_SESSION, which
# turns transcript saving off). A session already open is only focused. Woken sessions stay idle until the
# integration messages them. The ids, the names and the workspaces are read from the installed registry only;
# a name lists its conversations oldest first, and only the last, the current one, is opened. The workspace is the
# operator's .code-workspace FILE: opening a folder gives a new window, whose sessions die when it closes. The caller
# (CLAUDE_CODE_SESSION_ID, set in every session's shell) is already awake and is never reopened.
set -euo pipefail

log_file="${XDG_STATE_HOME:-$HOME/.local/state}/ndh-claude-wake/log"
dry=0
only=()

log() {
  mkdir -p "$(dirname "$log_file")"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$log_file"
}

refuse() {
  echo "ndh-claude-wake: refused: $*" >&2
  log "refused: $*"
  exit 3
}

run() {
  echo "+ $*"
  ((dry)) || "$@"
}

field() { # $1 = name, $2 = yq path below the session
  NAME="$1" yq -p=json -o=yaml ".sessions[strenv(NAME)]$2" "$registry"
}

while (($#)); do
  case $1 in
    --dry-run) dry=1 ;;
    --only) only+=("${2:?--only needs a name}"); shift ;;
    *) refuse "unknown argument: $1" ;;
  esac
  shift
done

[[ -r $registry ]] || refuse "no installed registry at $registry"
mapfile -t names < <(yq -p=json -o=yaml '.sessions | keys | .[]' "$registry")
((${#names[@]})) || refuse "the registry engraves no session"
for o in "${only[@]}"; do
  printf '%s\n' "${names[@]}" | grep -qx -- "$o" || refuse "$o is not engraved in the registry"
done
((${#only[@]})) && names=("${only[@]}")

declare -A opened_workspace=()
for name in "${names[@]}"; do
  workspace="$(field "$name" '.workspace // ""')"
  id="$(field "$name" '.conversations // [] | .[-1] // ""')"
  if [[ -z $workspace ]]; then
    echo "$name: no workspace engraved, skipped"
    log "$name: skipped, no workspace engraved"
    continue
  fi
  if ! [[ $id =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]]; then
    echo "$name: no valid conversation id engraved, skipped"
    log "$name: skipped, no valid conversation id"
    continue
  fi
  if [[ $id == "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "$name: the caller itself, skipped"
    log "$name $id: skipped, the caller"
    continue
  fi
  if [[ $workspace != *.code-workspace || ! -f $workspace ]]; then
    echo "$name: workspace $workspace is not an existing .code-workspace file, skipped"
    log "$name: skipped, no workspace file at $workspace"
    continue
  fi
  if [[ -z ${opened_workspace[$workspace]:-} ]]; then
    run open -b "$bundle" "$workspace"
    opened_workspace[$workspace]=1
    ((dry)) || sleep "$settle"
  fi
  run open "$scheme://anthropic.claude-code/open?session=$id"
  log "$name $id: opened in $workspace$( ((dry)) && echo ' (dry run)')"
done
