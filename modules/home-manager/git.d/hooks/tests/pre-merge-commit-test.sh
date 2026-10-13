#!/usr/bin/env bash
# The global pre-merge-commit runs the content guards on a merge: real merges, through the ACTUAL
# source hooks, in a throwaway repository whose .githooks/pre-commit is the canonical guard hook.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANON="${1:?usage: pre-merge-commit-test.sh <a repository .githooks/pre-commit carrying the content guards>}"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t
git config --global user.email t@t
git config --global init.defaultBranch topic
git config --global core.hooksPath "$HOOKS_DIR"
git config --global commit.gpgsign false

KEY=$'-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gt\n'

repo() { # $1 = name; a repo with the guard hook and a side branch adding $2 as file x
  local r="$T/$1"
  git init -q "$r"
  mkdir -p "$r/.githooks" && cp "$CANON" "$r/.githooks/pre-commit" && chmod +x "$r/.githooks/pre-commit"
  printf 'base\n' >"$r/base" && git -C "$r" add base .githooks && git -C "$r" commit -q -m base
  git -C "$r" checkout -q -b side
  printf '%s' "$2" >"$r/x" && git -C "$r" add x && git -C "$r" commit -q --no-verify -m side
  git -C "$r" checkout -q topic
  printf 'other\n' >"$r/other" && git -C "$r" add other && git -C "$r" commit -q -m other
  printf '%s' "$r"
}

echo "pre-merge-commit:"
r="$(repo clean 'plain content')"
git -C "$r" merge -q --no-ff -m merge side >/dev/null 2>&1 && ok "a clean merge is made" || bad "a clean merge is made"

r="$(repo secret "$KEY")"
if git -C "$r" merge -q --no-ff -m merge side >/dev/null 2>&1; then
  bad "a merge bringing a private key is refused"
else
  ok "a merge bringing a private key is refused"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
