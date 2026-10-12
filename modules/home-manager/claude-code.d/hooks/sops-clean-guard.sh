#!/usr/bin/env bash
# A session's sops `clean` filter: pass a sops envelope through unchanged, refuse anything else.
#
# The session never encrypts — sops-git-env.sh neutralises the real clean — so what reaches git is
# what is on disk. If a checkout made OUTSIDE a session ran the real smudge, that is the clear text,
# and a plain `cat` would commit it. An envelope carries ENC[…] values and sops metadata; a file that
# lacks either is refused, and with filter.<driver>.required the `git add` fails.
#
# The content is tested in pure bash. A here-string may be backed by a temporary FILE, and a refused
# content is the clear text: it must not land in $TMPDIR. A pipe to grep -q could SIGPIPE under
# pipefail and refuse a valid envelope at random.
set -euo pipefail

content="$(
  cat
  printf x
)"
content="${content%x}"
nl=$'\n'
if [[ $content == *'ENC['* ]] &&
  { [[ $content =~ (^|$nl)(sops:|sops_|\[sops\]) ]] || [[ $content =~ \"sops\"[[:space:]]*: ]]; }; then
  printf '%s' "$content"
  exit 0
fi
echo "sops clean: ${1:-a sops-managed file} is not a sops envelope on disk — refusing to stage it." >&2
echo "  Re-encrypt it (sops --encrypt --in-place) before adding it." >&2
exit 1
