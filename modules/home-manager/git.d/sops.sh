#!/usr/bin/env bash
# -*- mode: sh -*-
# The git sops DIFF driver: a textconv that renders a sops blob decrypted, so `git diff` shows
# what moved instead of two walls of ciphertext. It is a diff driver only — no clean/smudge
# filter: sops files stay encrypted on disk everywhere and are opened in memory by their readers,
# so nothing is encrypted at `git add` nor decrypted at checkout.
# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset BASH_XTRACEFD 2>/dev/null || true

set -euo pipefail

git::sops::show() {
  printf "%s\n" "${@}"
}

# Wrapper
git::sops() {
  local operation="$1"
  case $operation in
  show)
    git::sops::"${operation}" "${@:2}"
    ;;
  decrypt)
    local filecontent

    [[ -z "${filecontent:=$( cat /dev/stdin )}" ]] &&
      return

    git::sops::"${operation}" <<<"${filecontent}"
    ;;
  esac
}

declare -A SCRIPT

SCRIPT[name]="$( basename "$0" )"

if [[ -L "${0}" ]]; then
  # Invoked through a per-format link, `<format>-textconv`: git hands a textconv a PATH and no
  # stdin, so point stdin at the blob and re-exec as the decrypt operation.
  test $# -ge 1
  OP=${SCRIPT[name]##*-}
  FORMAT=${SCRIPT[name]%%[-]*}
  FILE="$1"
  [[ "$OP" == "textconv" ]] || exit 1
  exec <"${FILE}"
  exec "$(realpath "$0")" decrypt "$FORMAT" "${@}"
fi

# The blob comes on stdin; there must be one.
test ! -t 0

# The operation (decrypt) and the format, as the textconv link re-execs us.
OP="${1}"
FORMAT="${2}"
FILE="${3}"

# The file name goes to sops --filename-override, which picks the input format from it.
declare -A META=(
  [filePath]="${FILE}"
  [fileName]="$(basename "${FILE}")"
  [fileFormat]="${FORMAT}"
)

if [[ -n "${META[fileFormat]}" && "${META[fileFormat]}" != "binary" ]]; then
  git::sops::decrypt() {
    sops --decrypt --input-type=yaml --output-type=yaml --filename-override="${META[fileName]}" /dev/stdin |
      yq --input-format=yaml --output-format="${META[fileFormat]}" eval . /dev/stdin
  }
else
  git::sops::decrypt() {
    sops --decrypt --input-type=binary --output-type=binary --filename-override="${META[fileName]}" /dev/stdin
  }
fi

case "${OP}" in
"decrypt")
  # Decrypt the blob for `git diff`. Capture it first so a non-sops blob can be passed through.
  INPUT="$(cat)"
  TMP=$(mktemp)
  decrypt_rc=0
  DECRYPTED=$(git::sops decrypt <<<"${INPUT}" 2>"$TMP") || decrypt_rc=$?
  err=$(cat "$TMP")
  rm "$TMP"
  if [[ $err == *"sops metadata not found"* ]]; then
    # Not a sops blob: render it as it is.
    git::sops show "${INPUT}"
  elif ((decrypt_rc != 0)); then
    # No key, or a corrupt blob. Never render it as EMPTY — two differing secrets would then diff
    # as identical, a silent lie exactly where a human is looking for a change. A non-zero textconv
    # makes git fall back to the raw blob: unreadable, but honest.
    echo >&2 "sops textconv: cannot decrypt ${META[filePath]} (rc=${decrypt_rc}) — git will diff the raw blob."
    exit "${decrypt_rc}"
  else
    git::sops show "${DECRYPTED}"
  fi
  ;;
*)
  exit 1
  ;;
esac
