#!/usr/bin/env bash
set -euo pipefail

OMO_HOME="${OMO_HOME:-$HOME/.omo}"
OMO_JSON="${OMO_JSON:-$OMO_HOME/omo.jsonc}"
AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
AGENTS_SKILLS="${AGENTS_SKILLS:-$AGENTS_HOME/skills}"
LOCK="${LOCK:-$AGENTS_HOME/.skill-lock.json}"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
FRAGMENTS_DIR="${FRAGMENTS_DIR:-$SCRIPT_DIR/../share/omo-patch}"
if [ ! -d "$FRAGMENTS_DIR/omo.d" ]; then
  if [ -d "$SCRIPT_DIR/../omo.d" ]; then
    FRAGMENTS_DIR="$SCRIPT_DIR/.."
  fi
fi

DRY_RUN=0
TARGET=""
PROFILE=""

usage() {
  cat <<'EOF'
Usage: omo-patch [options] <command> [args]

Commands:
  list                      List skills (present + enabled/disabled)
  add <skill>               Enable a skill (remove from disabled_skills)
  remove <skill>            Disable a skill (add to disabled_skills)
  --profile <name>          Apply a named profile fragment
  --dry-run                 Print actions without writing
  --target <path>           Override target file (default: ~/.omo/omo.jsonc)

Options:
  --help                    Show this help
EOF
}


log() { printf '%s\n' "$*"; }

backup_file() {
  local f="$1"
  if [ -f "$f" ]; then
    local ts; ts="$(date +%Y%m%dT%H%M%S)"
    local bak="${f}.omo-patch.bak.${ts}"
    cp -p "$f" "$bak"
    printf '%s' "$bak"
  fi
}

restore_file() {
  local f="$1" bak="$2"
  [ -f "$bak" ] && cp -p "$bak" "$f"
}

yq_value_expr() {
  local v="$1"
  case "$v" in
    true|false|null) printf '%s' "$v" ;;
    \{*|\[*)
      printf '%s' "$v" ;;
    *)
      if printf '%s' "$v" | grep -Eq '^-?[0-9]+(\.[0-9]+)?$'; then
        printf '%s' "$v"
      else
        local esc; esc="${v//\\/\\\\}"; esc="${esc//\"/\\\"}"
        printf '"%s"' "$esc"
      fi
      ;;
  esac
}

json_set() {
  local file="$1" path="$2" value="$3"
  [ -f "$file" ] || { echo "missing file: $file" >&2; return 1; }
  local expr_val; expr_val="$(yq_value_expr "$value")"
  local tmp="${file}.omo-patch.tmp"
  local bak; bak="$(backup_file "$file")"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] set $path = $value in $file"
    [ -n "$bak" ] && rm -f "$bak"
    return 0
  fi
  if ! yq -p json -o json "$path = $expr_val" "$file" > "$tmp" 2>/dev/null; then
    restore_file "$file" "$bak"
    rm -f "$tmp"
    echo "json_set failed: $path" >&2
    return 1
  fi
  if ! yq -p json '.' "$tmp" >/dev/null 2>&1; then
    restore_file "$file" "$bak"
    rm -f "$tmp"
    echo "invalid json after set: $path" >&2
    return 1
  fi
  mv "$tmp" "$file"
  log "set $path in $file"
}

json_merge() {
  local file="$1" path="$2" value="$3"
  [ -f "$file" ] || { echo "missing file: $file" >&2; return 1; }
  local tmp="${file}.omo-patch.tmp"
  local bak; bak="$(backup_file "$file")"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] merge $value into $path in $file"
    [ -n "$bak" ] && rm -f "$bak"
    return 0
  fi
  if ! yq -p json -o json "$path = ($path // {}) * $value" "$file" > "$tmp" 2>/dev/null; then
    if ! yq -p json -o json ". = . * $value" "$file" > "$tmp" 2>/dev/null; then
      restore_file "$file" "$bak"
      rm -f "$tmp"
      echo "json_merge failed" >&2
      return 1
    fi
  fi
  if ! yq -p json '.' "$tmp" >/dev/null 2>&1; then
    restore_file "$file" "$bak"
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
  log "merged into $file"
}

json_delete() {
  local file="$1" path="$2"
  [ -f "$file" ] || { echo "missing file: $file" >&2; return 1; }
  local tmp="${file}.omo-patch.tmp"
  local bak; bak="$(backup_file "$file")"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] delete $path in $file"
    [ -n "$bak" ] && rm -f "$bak"
    return 0
  fi
  if ! yq -p json -o json "del($path)" "$file" > "$tmp" 2>/dev/null; then
    restore_file "$file" "$bak"
    rm -f "$tmp"
    echo "json_delete failed: $path" >&2
    return 1
  fi
  if ! yq -p json '.' "$tmp" >/dev/null 2>&1; then
    restore_file "$file" "$bak"
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
  log "deleted $path in $file"
}

apply_json_op() {
  local file="$1" op="$2" path="$3" value="${4:-}"
  case "$op" in
    set) json_set "$file" "$path" "$value" ;;
    merge) json_merge "$file" "$path" "$value" ;;
    delete) json_delete "$file" "$path" ;;
    *) echo "unknown json op: $op" >&2; return 1 ;;
  esac
}

apply_md_replace() {
  local file="$1" heading="$2" content="$3"
  [ -f "$file" ] || { echo "missing file: $file" >&2; return 1; }
  local bak; bak="$(backup_file "$file")"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] replace heading '$heading' in $file"
    [ -n "$bak" ] && rm -f "$bak"
    return 0
  fi
  if ! printf '%s\n' "$content" | mdpatch patch replace heading "$heading" "$file" >/dev/null 2>&1; then
    restore_file "$file" "$bak"
    echo "md replace failed: $heading" >&2
    return 1
  fi
  log "replaced heading '$heading' in $file"
}


lock_add() {
  local skill="$1"
  mkdir -p "$(dirname "$LOCK")"
  if [ ! -f "$LOCK" ]; then
    printf '{ "skills": {} }\n' > "$LOCK"
  fi
  local tmp="${LOCK}.tmp"
  local bak; bak="$(backup_file "$LOCK")"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] lock add $skill"
    [ -n "$bak" ] && rm -f "$bak"
    return 0
  fi
  if ! yq -p json -o json ".skills.${skill} = {\"enabled\": true}" "$LOCK" > "$tmp" 2>/dev/null; then
    restore_file "$LOCK" "$bak"
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$LOCK"
  log "lock: added $skill"
}

lock_remove() {
  local skill="$1"
  [ -f "$LOCK" ] || return 0
  local tmp="${LOCK}.tmp"
  local bak; bak="$(backup_file "$LOCK")"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] lock remove $skill"
    [ -n "$bak" ] && rm -f "$bak"
    return 0
  fi
  if ! yq -p json -o json "del(.skills.${skill})" "$LOCK" > "$tmp" 2>/dev/null; then
    restore_file "$LOCK" "$bak"
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$LOCK"
  log "lock: removed $skill"
}


recompute_disabled_skills() {
  local file="${1:-$OMO_JSON}"
  [ -f "$file" ] || return 0
  local present=()
  if [ -d "$AGENTS_SKILLS" ]; then
    for d in "$AGENTS_SKILLS"/*/; do
      [ -d "$d" ] || continue
      present+=("$(basename "$d")")
    done
  fi
  local current
  current="$(yq -p json -r '.disabled_skills // [] | .[]' "$file" 2>/dev/null)"
  local new=()
  while IFS= read -r skill; do
    [ -z "$skill" ] && continue
    for pp in "${present[@]}"; do
      if [ "$skill" = "$pp" ]; then new+=("$skill"); fi
    done
  done <<< "$current"
  local json="["
  local first=1
  for ss in "${new[@]}"; do
    if [ $first -eq 1 ]; then first=0; else json+=","; fi
    json+="\"$ss\""
  done
  json+="]"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] recompute disabled_skills in $file"
    return 0
  fi
  json_set "$file" ".disabled_skills" "$json"
  log "recomputed disabled_skills in $file"
}


enable_skill() {
  local skill="$1" file="${2:-$OMO_JSON}"
  [ -f "$file" ] || { echo "missing file: $file" >&2; return 1; }
  local tmp="${file}.omo-patch.tmp"
  local bak; bak="$(backup_file "$file")"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] enable $skill in $file"
    [ -n "$bak" ] && rm -f "$bak"
    return 0
  fi
  if ! yq -p json -o json ".disabled_skills = ((.disabled_skills // []) - [\"$skill\"])" "$file" > "$tmp" 2>/dev/null; then
    restore_file "$file" "$bak"
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
  lock_remove "$skill"
  log "enabled $skill"
}

disable_skill() {
  local skill="$1" file="${2:-$OMO_JSON}"
  [ -f "$file" ] || { echo "missing file: $file" >&2; return 1; }
  local tmp="${file}.omo-patch.tmp"
  local bak; bak="$(backup_file "$file")"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] disable $skill in $file"
    [ -n "$bak" ] && rm -f "$bak"
    return 0
  fi
  if ! yq -p json -o json ".disabled_skills = (((.disabled_skills // []) + [\"$skill\"]) | unique)" "$file" > "$tmp" 2>/dev/null; then
    restore_file "$file" "$bak"
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
  lock_add "$skill"
  log "disabled $skill"
}
load_profile() {
  local profile="$1"
  local frag="$FRAGMENTS_DIR/omo.d/${profile}.yaml"
  if [ ! -f "$frag" ]; then
    echo "missing fragment: $frag" >&2
    return 1
  fi
  local tcount; tcount="$(yq -r '.targets | length' "$frag" 2>/dev/null || echo 0)"
  local i
  for ((i=0; i<tcount; i++)); do
    local tpath tkind
    tpath="$(yq -r ".targets[$i].path" "$frag")"
    tkind="$(yq -r ".targets[$i].kind" "$frag")"
    tpath="${tpath/#\~/$HOME}"
    local pcount; pcount="$(yq -r ".targets[$i].patches | length" "$frag" 2>/dev/null || echo 0)"
    local j
    for ((j=0; j<pcount; j++)); do
      local op pth val
      op="$(yq -r ".targets[$i].patches[$j].op" "$frag")"
      pth="$(yq -r ".targets[$i].patches[$j].path" "$frag")"
      val="$(yq -r ".targets[$i].patches[$j].value" "$frag")"
      case "$tkind" in
        json) apply_json_op "$tpath" "$op" "$pth" "$val" ;;
        markdown)
          if [ "$op" = "replace" ]; then
            apply_md_replace "$tpath" "$pth" "$val"
          fi
          ;;
      esac
    done
  done
  recompute_disabled_skills "$OMO_JSON"
  log "profile '$profile' applied"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    --help|-h|help)
      usage; exit 0 ;;
    list)
      shift || true
      log "Skills in $AGENTS_SKILLS:"
      if [ -d "$AGENTS_SKILLS" ]; then
        for d in "$AGENTS_SKILLS"/*/; do
          [ -d "$d" ] || continue
          local_skill="$(basename "$d")"
          status="enabled"
          if yq -p json -e ".disabled_skills | contains([\"$local_skill\"])" "$OMO_JSON" >/dev/null 2>&1; then
            status="disabled"
          fi
          printf '  %s  (%s)\n' "$local_skill" "$status"
        done
      fi
      exit 0
      ;;
    add)
      skill="${2:-}"
      [ -n "$skill" ] || { echo "missing skill name" >&2; exit 2; }
      if [ ! -d "$AGENTS_SKILLS/$skill" ]; then
        echo "skill not present: $skill" >&2
        exit 1
      fi
      enable_skill "$skill"
      exit 0
      ;;
    remove)
      skill="${2:-}"
      [ -n "$skill" ] || { echo "missing skill name" >&2; exit 2; }
      disable_skill "$skill"
      exit 0
      ;;
    --profile)
      PROFILE="${2:-}"
      [ -n "$PROFILE" ] || { echo "missing profile name" >&2; exit 2; }
      shift 2
      while [ $# -gt 0 ]; do
        case "$1" in
          --dry-run) DRY_RUN=1; shift ;;
          --target) TARGET="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      [ -n "$TARGET" ] && OMO_JSON="$TARGET"
      load_profile "$PROFILE"
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      if [ "${1:-}" = "--profile" ]; then
        PROFILE="${2:-}"
        shift 2
        [ -n "$PROFILE" ] || { echo "missing profile name" >&2; exit 2; }
        [ -n "$TARGET" ] && OMO_JSON="$TARGET"
        load_profile "$PROFILE"
        exit 0
      fi
      usage; exit 0
      ;;
    --target)
      TARGET="${2:-}"
      shift 2
      if [ "${1:-}" = "--profile" ]; then
        PROFILE="${2:-}"
        shift 2
        [ -n "$PROFILE" ] || { echo "missing profile name" >&2; exit 2; }
        [ -n "$TARGET" ] && OMO_JSON="$TARGET"
        load_profile "$PROFILE"
        exit 0
      fi
      usage; exit 0
      ;;
    "")
      usage; exit 0
      ;;
    *)
      echo "unknown command: $cmd" >&2
      usage >&2
      exit 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
