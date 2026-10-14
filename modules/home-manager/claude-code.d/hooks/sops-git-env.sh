#!/usr/bin/env bash
# SessionStart hook: every Bash command of the session keeps the FULL global git config — the
# identity, the signing, the hooks — with ONLY the sops drivers neutralised.
#
# A session must never run a sops smudge or textconv: either one decrypts, and a `git diff` of a
# sops file would put the clear values in the session's context. The former answer was to drop the
# whole global config (GIT_CONFIG_GLOBAL=/dev/null), which also dropped the signing and every hook:
# a commit made that way is unsigned, under user@host, and no pre-commit guard reads it. Instead,
# each sops driver the git config defines gets cat for its smudge and textconv, and for its clean a
# guard that passes a sops envelope and refuses anything else (sops-clean-guard.sh).
#
# The drivers are read as git reads them anywhere — system, ~/.gitconfig, ~/.config/git/config and
# their includes — not with --global, which reads ONE of those files: with a ~/.gitconfig present
# it skips the XDG config where the drivers live, and the hook would neutralise nothing.
#
# Claude Code runs $CLAUDE_ENV_FILE before each Bash command. The lines added there are guarded,
# so a file read twice adds nothing, and they append to any GIT_CONFIG_COUNT already set. After
# writing, the hook reads the file back and checks every override; a mismatch is said loudly.
set -euo pipefail

[[ -n "${CLAUDE_ENV_FILE:-}" ]] || exit 0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
clean="$BASH $here/sops-clean-guard.sh %f"

mapfile -t drivers < <(
  git -C / config --includes --name-only --get-regexp '^(filter|diff)\.sops-' 2>/dev/null |
    sed -E 's/^(filter|diff)\.([^.]+)\..*$/\2/' | sort -u
)
((${#drivers[@]})) || exit 0

overrides() { # one "key<TAB>value" line per override
  local d
  for d in "${drivers[@]}"; do
    printf 'filter.%s.smudge\tcat\n' "$d"
    printf 'filter.%s.clean\t%s\n' "$d" "$clean"
    printf 'filter.%s.required\ttrue\n' "$d"
    printf 'diff.%s.textconv\tcat\n' "$d"
  done
}

{
  printf '%s\n' 'if [ -z "${CLAUDE_SOPS_GIT_NEUTRAL:-}" ]; then'
  printf '%s\n' '  __n=${GIT_CONFIG_COUNT:-0}'
  while IFS=$'\t' read -r key value; do
    # Quoted NAME=VALUE: the file is read by bash or zsh, whichever the Bash tool runs.
    printf '  export "GIT_CONFIG_KEY_${__n}=%s" "GIT_CONFIG_VALUE_${__n}=%s"; __n=$((__n + 1))\n' "$key" "$value"
  done < <(overrides)
  printf '%s\n' '  export GIT_CONFIG_COUNT=$__n CLAUDE_SOPS_GIT_NEUTRAL=1'
  printf '%s\n' '  unset __n'
  printf '%s\n' 'fi'
} >>"$CLAUDE_ENV_FILE"

# Read the file back, as a Bash command would, and check every override took.
mismatch="$(
  unset CLAUDE_SOPS_GIT_NEUTRAL GIT_CONFIG_COUNT
  # shellcheck disable=SC1090
  . "$CLAUDE_ENV_FILE"
  while IFS=$'\t' read -r key value; do
    [ "$(git -C / config --get "$key")" = "$value" ] || printf '%s ' "$key"
  done < <(overrides)
)"
if [ -n "$mismatch" ]; then
  jq -cn --arg m "$mismatch" '{systemMessage: ("⛔ sops-git-env: these sops git overrides did not take — a git diff or checkout of a sops file may decrypt in this session: " + $m)}'
fi
