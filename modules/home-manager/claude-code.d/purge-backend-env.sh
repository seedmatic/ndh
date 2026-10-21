source @nixBashTrampoline@

# Delete the backend keys from ~/.claude.json's legacy `env` block. Claude Code applies that block in-process, under
# settings.json's, so a key settings.json does not set wins there: measured 2026-10-21, CLAUDE_CODE_USE_BEDROCK=1 and an
# AWS_PROFILE left in it kept a seat on Bedrock after its switch to the gateway, with no credentials. The backend is
# modules/claude-code-backend-env.nix's alone; every other key of the block is kept.
#
# Claude Code owns and rewrites ~/.claude.json at runtime, so the file is edited only when one of those keys is
# present, never reformatted otherwise. Idempotent: a no-op once they are gone.
main() {
  set -euo pipefail
  CFG="$HOME/.claude.json"
  [ -f "$CFG" ] || exit 0
  found="$(BACKEND='@backendKeys@' yq -p=json -o=json '[.env // {} | keys[] | select(test(strenv(BACKEND)))] | length' "$CFG")"
  if [ "$found" -gt 0 ]; then
    BACKEND='@backendKeys@' yq -i -p=json -o=json 'del(.env[] | select(key | test(strenv(BACKEND))))' "$CFG"
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
