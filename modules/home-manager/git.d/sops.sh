#!/usr/bin/env bash
# -*- mode: sh -*-
# The git sops drivers, for the repositories whose .gitattributes name them (keyhole; never a
# repository holding a flake, so nix never evaluates a decrypted tree):
#   - diff textconv: renders a sops blob decrypted, so `git diff` shows what moved;
#   - filter smudge: decrypts at checkout, and writes nothing when it cannot;
#   - filter clean: encrypts at `git add`, for the recipients of the file's OWN creation rule.
# Claude sessions neutralise all of them (claude-code.d/hooks/sops-git-env.sh).
# The filters hold the plaintext only in a 0700 directory under the user's TMPDIR, removed on exit; a
# SIGKILL skips that trap and can leave it there, private to the user, until the system's tmp sweep.
# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
unset BASH_XTRACEFD 2>/dev/null || true
unset BASH_ENV # a caller's BASH_ENV holding `set -x` would trace every child bash this script starts

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
  # Invoked through a per-format link, `<format>-<op>`. git hands a textconv a PATH and no stdin,
  # so point stdin at the blob and re-exec as decrypt; a filter gets the content on stdin and the
  # path (%f) as its argument, and keeps both.
  test $# -ge 1
  OP=${SCRIPT[name]##*-}
  FORMAT=${SCRIPT[name]%%[-]*}
  FILE="$1"
  case "$OP" in
  textconv)
    exec <"${FILE}"
    exec "$(realpath "$0")" decrypt "$FORMAT" "${@}"
    ;;
  clean | smudge)
    exec "$(realpath "$0")" "$OP" "$FORMAT" "${@}"
    ;;
  *) exit 1 ;;
  esac
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

# The filters work on files in a private directory: a binary blob does not survive a shell variable.
filter::type() { [[ "${META[fileFormat]}" == binary ]] && echo binary || echo yaml; }
filter::encrypted() { # <file>
  [[ "$(sops filestatus --input-type "$(filter::type)" "$1" 2>/dev/null)" == *'"encrypted":true'* ]]
}
filter::workdir() {
  umask 077
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  cat >"$WORK/in"
}

case "${OP}" in
"smudge")
  filter::workdir
  if ! filter::encrypted "$WORK/in"; then
    cat "$WORK/in"
    exit 0
  fi
  # Decrypted into a file first: on failure nothing reaches git, so no empty or partial file is
  # written, and filter.<driver>.required makes the checkout fail on this path.
  if ! sops --decrypt --input-type "$(filter::type)" --output-type "$(filter::type)" "$WORK/in" >"$WORK/out" 2>/dev/null; then
    # sops' own stderr can quote the plaintext: never relay it.
    echo >&2 "sops smudge: cannot decrypt ${META[filePath]} (no matching key, or a corrupt envelope); nothing written"
    exit 1
  fi
  cat "$WORK/out"
  ;;
"clean")
  filter::workdir
  if filter::encrypted "$WORK/in"; then
    cat "$WORK/in"
    exit 0
  fi
  # Idempotent: the plaintext of the index's (else HEAD's) blob unchanged → that blob, byte for
  # byte, so a re-encryption with fresh IVs never shows an unchanged file as modified.
  for rev in ":" "HEAD:"; do
    if git cat-file -e "${rev}${META[filePath]}" 2>/dev/null; then
      git cat-file blob "${rev}${META[filePath]}" >"$WORK/prev"
      if filter::encrypted "$WORK/prev" &&
        sops --decrypt --input-type "$(filter::type)" --output-type "$(filter::type)" "$WORK/prev" >"$WORK/prev.plain" 2>/dev/null &&
        cmp -s "$WORK/in" "$WORK/prev.plain"; then
        cat "$WORK/prev"
        exit 0
      fi
      break
    fi
  done
  # Encrypted at the file's own path in a copy of the repository's .sops.yaml: sops picks the
  # creation rule from the path it encrypts, and --filename-override does not change that choice.
  root="$(git rev-parse --show-toplevel)"
  if [[ ! -f "$root/.sops.yaml" ]]; then
    echo >&2 "sops clean: ${META[filePath]}: no .sops.yaml at the repository root, so no recipients"
    exit 1
  fi
  mkdir -p "$WORK/repo/$(dirname "${META[filePath]}")"
  cp "$root/.sops.yaml" "$WORK/repo/.sops.yaml"
  cp "$WORK/in" "$WORK/repo/${META[filePath]}"
  if ! (cd "$WORK/repo" && sops encrypt --input-type "$(filter::type)" --output-type "$(filter::type)" "${META[filePath]}") >"$WORK/out" 2>/dev/null; then
    echo >&2 "sops clean: cannot encrypt ${META[filePath]} (its creation rule, or not $(filter::type)); run sops on it by hand to see why"
    exit 1
  fi
  cat "$WORK/out"
  ;;
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
