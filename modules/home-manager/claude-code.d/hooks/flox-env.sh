#!/usr/bin/env bash
# SessionStart hook: a session started in a flox repository gets that repository's flox environment — its tools on
# PATH, FLOX_ENV and the env's variables — in every Bash command, as a terminal of that repository would.
#
# The Flox VS Code extension used to bring it, by restoring at every extension-host start a snapshot of the WHOLE
# process environment taken at its last activation. A snapshot from the Bedrock days kept a seat on Bedrock after the
# switch to the gateway (measured 2026-10-21); the extension is disabled since. So the environment is taken fresh at
# each session start, by `flox activate` itself, and only what flox CHANGES is kept: the diff of the environment
# before and after the activation. A backend key is never taken from it, whatever an env declares: the backend is
# settings.json's alone (modules/claude-code-backend-env.nix).
#
# Claude Code runs $CLAUDE_ENV_FILE before each Bash command; the lines added here are guarded, so a file read twice
# adds nothing. A repository is a flox one when its root holds .flox/env/manifest.toml. An activation that fails or
# takes too long is said in one line, and the session goes on without it.
#
# Activating runs the manifest's hook, arbitrary code, at every session start and with no prompt: so only the
# operator's own repositories are activated (@trustedRoots@), never a cloned third-party one. And nothing the env sets
# may undo what sops-git-env neutralised: no GIT_CONFIG_* nor GIT_DIR, GIT_WORK_TREE, GIT_EXEC_PATH is taken.
set -euo pipefail

[[ -n "${CLAUDE_ENV_FILE:-}" ]] || exit 0
input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -n "$cwd" && -d "$cwd" ]] || exit 0
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$root" && -f "$root/.flox/env/manifest.toml" ]] || exit 0
trusted=""
for t in @trustedRoots@; do [[ "$root/" == "$t"/* ]] && trusted=1; done
[[ -n "$trusted" ]] || exit 0
# Named by the seat's profile, never looked up on the session's PATH.
flox="@floxProfile@/$(id -un)/bin/flox"
[[ -x "$flox" ]] || exit 0

backend='@backendKeys@'
# The variables a flox activation sets for its own bookkeeping, or that only make sense inside the activated shell,
# and the git ones sops-git-env owns.
skip='^(_|_flox_.*|_FLOX_.*|_activate_d|FLOX_PROMPT_.*|SHLVL|PWD|OLDPWD|GIT_CONFIG.*|GIT_DIR|GIT_WORK_TREE|GIT_EXEC_PATH)$'

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
env -0 >"$tmp/before"
# Quiet: no FloxHub reminder, no metrics, nothing on the session's screen but our own line.
if ! FLOX_AUTH_NOTIFICATIONS=false FLOX_DISABLE_METRICS=true timeout 30 \
  "$flox" activate -d "$root" -- env -0 >"$tmp/after" 2>"$tmp/err"; then
  jq -cn --arg r "$root" --arg e "$(tail -c 300 "$tmp/err")" \
    '{systemMessage: ("flox-env: the flox environment of " + $r + " did not activate; this session runs without it: " + $e)}'
  exit 0
fi

# NAME=VALUE pairs set or changed by the activation, minus bookkeeping and backend keys, quoted for bash and zsh.
lines="$(
  BEFORE="$tmp/before" AFTER="$tmp/after" BACKEND="$backend" SKIP="$skip" "@python@" -I -c '
import os, re, shlex
def load(p):
    d = {}
    for kv in open(p, "rb").read().split(b"\0"):
        if b"=" in kv:
            k, v = kv.split(b"=", 1)
            d[k.decode()] = v.decode(errors="replace")
    return d
a, b = load(os.environ["BEFORE"]), load(os.environ["AFTER"])
backend, skip = re.compile(os.environ["BACKEND"]), re.compile(os.environ["SKIP"])
for k in sorted(b):
    if b[k] != a.get(k) and not backend.match(k) and not skip.match(k) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k):
        print("  export " + shlex.quote(k + "=" + b[k]))
'
)"
[[ -n "$lines" ]] || exit 0

{
  printf '%s\n' 'if [ -z "${CLAUDE_FLOX_ENV:-}" ]; then'
  printf '%s\n' "$lines"
  printf '  export CLAUDE_FLOX_ENV=%q\n' "$root"
  printf '%s\n' 'fi'
} >>"$CLAUDE_ENV_FILE"
