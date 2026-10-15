#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok and bad never fail, so `A && ok || bad` is an if-then-else here
# Regression suite for the sops-filter guard. Runs the ACTUAL source hooks against scratch repos, with no
# sops driver defined: check-attr reports the ATTRIBUTE, which is what the guard judges. Run it in an
# environment free of a Claude session's GIT_CONFIG_* neutralisers (env -i), or its clean guard refuses
# the scratch commits.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL="$(cd "$HOOKS_DIR/../../../.." && pwd)/.githooks/pre-commit"
PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
git config --global user.name tester
git config --global user.email tester@example.invalid
git config --global init.defaultBranch feature

repo() { # $1 = name, $2 = with-flake | no-flake
  local r="$T/$1"
  mkdir -p "$r" && git -C "$r" init -q
  [ "$2" = with-flake ] && echo '{ outputs = _: { }; }' >"$r/flake.nix"
  printf 'token: in-the-clear\n' >"$r/secret.yaml"
  git -C "$r" add -A && git -C "$r" commit -qm init
  echo "$r"
}
run_in() { (cd "$1" && shift && "$@") >"$T/out" 2>&1; echo $?; }

echo "global pre-commit:"
r=$(repo staged with-flake); printf '*.yaml filter=sops-yaml\n' >"$r/.gitattributes"; git -C "$r" add .gitattributes
[ "$(run_in "$r" "$HOOKS_DIR/pre-commit")" = 1 ] && grep -q 'secret.yaml filter=sops-yaml' "$T/out" && ok "staged filter= in a flake repo: refused" || bad "staged filter= in a flake repo"

r=$(repo info with-flake); printf 'secret.yaml filter=sops-binary\n' >"$r/.git/info/attributes"
[ "$(run_in "$r" "$HOOKS_DIR/pre-commit")" = 1 ] && ok ".git/info/attributes in a flake repo: refused" || bad ".git/info/attributes in a flake repo"

r=$(repo wt with-flake); printf 'secret.yaml filter=sops-yaml\n' >"$r/.gitattributes"
[ "$(run_in "$r" "$HOOKS_DIR/pre-commit")" = 1 ] && ok "unstaged worktree .gitattributes in a flake repo: refused" || bad "unstaged worktree .gitattributes"

r=$(repo diffonly with-flake); printf '*.yaml diff=sops-yaml\n' >"$r/.gitattributes"; git -C "$r" add .gitattributes
[ "$(run_in "$r" "$HOOKS_DIR/pre-commit")" = 0 ] && ok "diff= only in a flake repo: allowed" || bad "diff= only in a flake repo"

r=$(repo noflake no-flake); printf '*.yaml filter=sops-yaml\n' >"$r/.gitattributes"; git -C "$r" add .gitattributes
[ "$(run_in "$r" "$HOOKS_DIR/pre-commit")" = 0 ] && ok "filter= in a repo without a flake: allowed" || bad "filter= without a flake"

echo "global post-checkout / post-merge:"
r=$(repo announce with-flake); printf '*.yaml filter=sops-yaml\n' >"$r/.gitattributes"
[ "$(run_in "$r" "$HOOKS_DIR/post-checkout" 0 0 1)" = 0 ] && grep -q 'secret.yaml  ← IN THE CLEAR ON DISK NOW' "$T/out" && ok "post-checkout announces, never fails" || bad "post-checkout announcement"
[ "$(run_in "$r" "$HOOKS_DIR/post-merge" 0)" = 0 ] && grep -q 'sops-filter-guard (post-merge)' "$T/out" && ok "post-merge announces under its own name" || bad "post-merge announcement"
r=$(repo quiet with-flake)
[ "$(run_in "$r" "$HOOKS_DIR/post-checkout" 0 0 1)" = 0 ] && [ ! -s "$T/out" ] && ok "post-checkout silent without filter=" || bad "post-checkout silence"

echo "canonical pre-commit (no nix on PATH, so the formatter is skipped, never the guards):"
mkdir -p "$T/bin" && ln -s "$(command -v git)" "$T/bin/git"
nonix="$T/bin:/usr/bin:/bin" # git alone: its own directory may also hold nix
r=$(repo canon with-flake); printf '*.yaml filter=sops-yaml\n' >"$r/.gitattributes"; git -C "$r" add .gitattributes
[ "$(cd "$r" && PATH="$nonix" "$CANONICAL" >"$T/out" 2>&1; echo $?)" = 1 ] && grep -q 'secret.yaml  filter=sops-yaml' "$T/out" && ok "canonical: staged filter= refused" || bad "canonical: staged filter="
r=$(repo canonok with-flake); printf '*.yaml diff=sops-yaml\n' >"$r/.gitattributes"; git -C "$r" add .gitattributes
[ "$(cd "$r" && PATH="$nonix" "$CANONICAL" >"$T/out" 2>&1; echo $?)" = 0 ] && ok "canonical: diff= only allowed" || bad "canonical: diff= only"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
