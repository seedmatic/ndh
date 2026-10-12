#!/usr/bin/env bash
# Regression suite for the pre-push signing guard. Real `git push` through the ACTUAL source hooks
# (not the deployed copies), into a throwaway bare remote, with throwaway SSH signing keys.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
ssh-keygen -q -t ed25519 -N '' -C trusted -f "$T/trusted"
ssh-keygen -q -t ed25519 -N '' -C stranger -f "$T/stranger"
ssh-keygen -q -t ed25519 -N '' -C bot -f "$T/bot"
{
  printf 'dev@example.invalid namespaces="git" %s\n' "$(cat "$T/trusted.pub")"
  # A bot key vouches for the bot identity pattern only, as generate-allowed-signers writes it.
  printf 'bot+*@example.invalid namespaces="git" %s\n' "$(cat "$T/bot.pub")"
} >"$T/allowed_signers"
git config --global user.name dev
git config --global user.email dev@example.invalid
git config --global gpg.format ssh
git config --global user.signingkey "$T/trusted.pub"
git config --global commit.gpgsign true
git config --global gpg.ssh.allowedSignersFile "$T/allowed_signers"
git config --global core.hooksPath "$HOOKS_DIR"
git config --global init.defaultBranch develop

fresh() { # a clone of an empty bare remote; echoes its path
  local d="$T/$1"
  git init -q --bare "$d.git"
  git clone -q "$d.git" "$d" 2>/dev/null
  printf '%s' "$d"
}
commit() { # $1 = repo, $2 = file, extra args to git commit
  local r="$1" f="$2"; shift 2
  printf '%s\n' "$f" >"$r/$f"
  git -C "$r" add "$f"
  git -C "$r" commit -q -m "$f" "$@"
}
pushes() { git -C "$1" push -q "${@:2}" >/dev/null 2>&1; }

echo "signing guard:"

r="$(fresh good)"
commit "$r" a
pushes "$r" origin develop && ok "a signed, trusted commit is pushed" || bad "a signed, trusted commit is pushed"

r="$(fresh unsigned)"
commit "$r" a --no-gpg-sign
pushes "$r" origin develop && bad "an unsigned commit is refused" || ok "an unsigned commit is refused"

r="$(fresh hostid)"
commit "$r" a --no-gpg-sign --author="nxmatic <nxmatic@host.lan>"
pushes "$r" origin develop && bad "an unsigned user@host commit is refused" || ok "an unsigned user@host commit is refused"

r="$(fresh author)"
commit "$r" a --author="someone <someone@else.invalid>"
pushes "$r" origin develop && bad "a signed commit under a foreign author is refused" || ok "a signed commit under a foreign author is refused"

r="$(fresh untrusted)"
printf 'a\n' >"$r/a" && git -C "$r" add a
git -C "$r" -c "user.signingkey=$T/stranger.pub" commit -q -m a
[ "$(git -C "$r" log -1 --format=%G?)" = U ] || bad "setup: the untrusted commit is signed but not trusted (U)"
pushes "$r" origin develop && bad "a commit signed by an untrusted key is refused" || ok "a commit signed by an untrusted key is refused"

r="$(fresh history)"
commit "$r" old --no-gpg-sign
git -C "$r" push -q --no-verify origin develop >/dev/null 2>&1
commit "$r" new
pushes "$r" origin develop && ok "published history is not judged again" || bad "published history is not judged again"

r="$(fresh delete)"
commit "$r" a
pushes "$r" origin develop
git -C "$r" push -q origin develop:refs/heads/doomed >/dev/null 2>&1
pushes "$r" origin :doomed && ok "a deletion is pushed" || bad "a deletion is pushed"

r="$(fresh merge)"
commit "$r" base
pushes "$r" origin develop
git -C "$r" checkout -q -b topic
commit "$r" topic
git -C "$r" checkout -q develop
commit "$r" side
git -C "$r" merge -q --no-ff -S -m "merge topic" topic
pushes "$r" origin develop && ok "a signed merge commit is pushed" || bad "a signed merge commit is pushed"

r="$(fresh tag)"
commit "$r" a
pushes "$r" origin develop
commit "$r" b --no-gpg-sign
git -C "$r" tag -a -s -m t v1
pushes "$r" origin v1 && bad "a tag that publishes an unsigned commit is refused" || ok "a tag that publishes an unsigned commit is refused"

as_bot() { # $1 = repo, $2 = signing key; commits as the render bot
  printf 'b\n' >"$1/b" && git -C "$1" add b
  GIT_AUTHOR_NAME=bot GIT_AUTHOR_EMAIL=bot+render@example.invalid GIT_COMMITTER_NAME=bot \
    GIT_COMMITTER_EMAIL=bot+render@example.invalid git -C "$1" -c "user.signingkey=$2" commit -q -m bot
}

r="$(fresh botok)"
as_bot "$r" "$T/bot.pub"
pushes "$r" origin develop && ok "a bot commit signed by the bot key is pushed" || bad "a bot commit signed by the bot key is pushed"

r="$(fresh botoperator)"
as_bot "$r" "$T/trusted.pub"
pushes "$r" origin develop && bad "a bot commit signed by the operator key is refused" || ok "a bot commit signed by the operator key is refused"

r="$(fresh botasdev)"
printf 'c\n' >"$r/c" && git -C "$r" add c
git -C "$r" -c "user.signingkey=$T/bot.pub" commit -q -m c
pushes "$r" origin develop && bad "the bot key cannot sign as the operator" || ok "the bot key cannot sign as the operator"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
