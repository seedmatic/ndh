source @nixBashTrampoline@

# Keep Claude's mutable files aligned with declarative Bedrock/AWS env.
# - ~/.claude/settings.json is updated in-place so GUI/CLI sessions that read
#   this file directly still use the canonical profile/region.
# - ~/.claude.json legacy env keys are removed to avoid precedence conflicts.
# Idempotent and no-op when files are absent.
main() {
  set -euo pipefail

  SETTINGS="$HOME/.claude/settings.json"
  LEGACY="$HOME/.claude.json"

  if [ -f "$SETTINGS" ]; then
    @python3@ - <<'PY'
import json
from pathlib import Path

settings = Path.home() / ".claude" / "settings.json"
if settings.exists():
    data = json.loads(settings.read_text())
    env = data.get("env")
    if not isinstance(env, dict):
        env = {}

    updates = {
        "CLAUDE_CODE_USE_BEDROCK": "@claudeCodeUseBedrock@",
        "AWS_PROFILE": "@awsProfile@",
        "AWS_REGION": "@awsRegion@",
        "AWS_DEFAULT_REGION": "@awsDefaultRegion@",
        "AWS_SDK_LOAD_CONFIG": "@awsSdkLoadConfig@",
    }

    changed = False
    for k, v in updates.items():
        if v and env.get(k) != v:
            env[k] = v
            changed = True

    if changed:
        data["env"] = env
        settings.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
  fi

  if [ -f "$LEGACY" ]; then
    @python3@ - <<'PY'
import json
from pathlib import Path

legacy = Path.home() / ".claude.json"
if legacy.exists():
    data = json.loads(legacy.read_text())
    env = data.get("env")
    if isinstance(env, dict):
        for k in [
            "AWS_PROFILE",
            "AWS_REGION",
            "AWS_DEFAULT_REGION",
            "AWS_SDK_LOAD_CONFIG",
            "CLAUDE_CODE_USE_BEDROCK",
        ]:
            env.pop(k, None)
        data["env"] = env
        legacy.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
