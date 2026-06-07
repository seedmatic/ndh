source @nixBashTrampoline@

# Remove the legacy env.ANTHROPIC_MODEL hard override from ~/.claude.json.
# That key (an onboarding-era remnant) pins the model above every settings.json
# "model" field, so it defeats both the user's chosen default and /model. The
# per-tier defaults live in cfg.env (ANTHROPIC_DEFAULT_OPUS_MODEL) instead.
# Claude Code owns and rewrites ~/.claude.json at runtime, so we edit only the
# one key and only when it is present — never reformatting the live file
# otherwise. Idempotent: a no-op once the key is gone.
main() {
  set -euo pipefail
  CFG="$HOME/.claude.json"
  [ -f "$CFG" ] || exit 0
  if [ "$(yq -p=json -o=json '.env | has("ANTHROPIC_MODEL")' "$CFG")" = "true" ]; then
    yq -i -o=json 'del(.env.ANTHROPIC_MODEL)' "$CFG"
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
