#!/usr/bin/env bash
# -*- mode: sh -*-
# Portable shebang: the host materialises /run/current-system via nix-darwin/nixos
# activation, but a flox container (the in-cluster render pod) has no such path — so
# the SSOT script targets /usr/bin/env (present on macOS, NixOS and standard containers)
# and moves the strict flags into the body, off the shebang's -S dependency.
set -euo pipefail

test -n "${GIT_TRACE:-}" && set -x

sops::config() {
  local fmt=${1}
  local name=sops-${fmt}

  cat <<EOF >sops.d/$fmt
[filter "$name"]
  clean = @sopsConfigHome@/$fmt-clean %f
  smudge = @sopsConfigHome@/$fmt-smudge %f
[diff "$name"]
  textconv = @sopsConfigHome@/$fmt-textconv
EOF
}

sops::bin() {
  local fmt=$1

  ln -fs ../sops.sh sops.d/$fmt-clean
  ln -fs ../sops.sh sops.d/$fmt-smudge
  ln -fs ../sops.sh sops.d/$fmt-textconv
}

sops::generate_config() {
  local -a formats=(binary yaml json xml props csv tsv base64 uri toml lua)

  # Generate individual format include files
  for fmt in "${formats[@]}"; do
    sops::config "$fmt"
    sops::bin "$fmt"
  done

  # Generate the main sops include file
  cat <<EOF >sops
[include]
$(for fmt in "${formats[@]}"; do
    echo "  path = sops.d/$fmt"
  done)
EOF

  # Generate sops.nix for Nix home-manager configuration
  cat <<EOF >sops.nix
{ config, lib, pkgs, ... }:

{
  programs.git = {
    includes = [
      { path = "sops"; }
    ];
  };

  xdg.configFile."git/sops" = {
    source = pkgs.replaceVars ./sops {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };
      nativeBuildInputs = [ pkgs.rsync ];
      buildInputs = [ pkgs.rsync ];
      
      installPhase = ''
        mkdir -p \$out
        rsync -av --exclude-from=<( printf '%s\n' ${formats[@]} ) \$src/ \$out/
      '';
    };
    recursive = true;
  };

  xdg.configFile."git/sops" = {
    source = pkgs.replaceVars ./sops {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

$(for fmt in "${formats[@]}"; do
    cat <<EOL

  xdg.configFile."git/sops.d/$fmt" = {
    source = pkgs.replaceVars ./sops.d/$fmt {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };
EOL
  done)
}
EOF
}

git::sops:input:yq:format() {
  case "${META[fileExt]}" in
  "yml" | "yaml")
    echo "yaml"
    ;;
  "json")
    echo "json"
    ;;
  "xml")
    echo "xml"
    ;;
  "env|dotenv|props|properties")
    echo "properties"
    ;;
  "csv")
    echo "csv"
    ;;
  "tsv")
    echo "tsv"
    ;;
  "base64" | "b64")
    echo "base64"
    ;;
  "uri")
    echo "uri"
    ;;
  "toml")
    echo "toml"
    ;;
  "lua")
    echo "lua"
    ;;
  *)
    echo "unsupported"
    ;;
  esac
}

git::sops::show() {
  printf "%s\n" "${@}"
}

# Append or strip the git sops trailer
GIT_SOPS_TRAILER="git::sops:trailer"

git::sops:input:trailer:concat() {
  cat <<!
  ${1:-$(cat /dev/stdin)}
  ${GIT_SOPS_TRAILER}
!
}

git::sops:input:trailer:strip() {
  echo "${1%${GIT_SOPS_TRAILER}}"
}

# Wrapper
git::sops() {
  local operation="$1"
  case $operation in
  show)
    git::sops::"${operation}" "${@:2}"
    ;;
  decrypt | encrypt | canonical)
    local filecontent

    [[ -z "${filecontent:=$( cat /dev/stdin )}" ]] &&
      return

    git::sops::"${operation}" <<<"${filecontent}"
    ;;
  esac
}

# Function to check if we're being called as a Git filter or textconv
sops::is_git_operation() {
  [[ -n "${GIT_DIR:-}" ]]
}

# Function to check if we're running under Nix
sops::is_nix_build() {
  [[ -n "${NIX_BUILD_TOP:-}" ]]
}

declare -A SCRIPT

SCRIPT[name]="$( basename "$0" )"
SCRIPT[dir]="$( dirname "$0" )"

if [[ -L "${0}" ]]; then
  # Exit if the file names were not given
  test $# -ge 1

  OP=${SCRIPT[name]##*-}       # Extract operation from script name
  FORMAT=${SCRIPT[name]%%[-]*} # Extract format from script name
  FILE="$1"                    # First argument as file

  # .sops.yaml (creation_rules) is needed only to ENCRYPT (clean). Decryption (smudge /
  # textconv) reads the sops metadata embedded in the blob + the age key, so it does NOT need
  # .sops.yaml — requiring it would make a checkout of any branch WITHOUT one fatally fail under
  # `required = true`. So guard clean ONLY: a clean with no policy refuses (never commit
  # plaintext); a smudge/textconv proceeds (decrypt by embedded metadata, or — for a plaintext
  # blob — pass through).
  if [[ "${OP}" == "clean" ]] && ! test -r .sops.yaml; then
    echo >&2 "sops clean filter: missing $(pwd)/.sops.yaml — refusing to stage (would commit plaintext)."
    exit 1
  fi

  case "$OP" in
  "textconv")
    # git hands textconv a PATH and no stdin, where clean/smudge are FED on stdin. So point stdin at
    # the blob, then take the SAME re-exec as every other arm — as SMUDGE, because a textconv exists
    # to render a blob READABLE for `git diff`, which for a sops file means decrypted. Smudge already
    # handles both shapes a textconv can be handed (git passes the raw blob for the index/HEAD side
    # and the smudged worktree file for the other): it decrypts what is encrypted and passes the rest
    # through.
    #
    # ⚠️ Two defects lived here, measured 2026-09-30. This arm redirected stdin and then FELL THROUGH
    # to the `exit 1` below — every other arm re-execs — so textconv returned nothing, with no
    # diagnostic, for every format; git then silently falls back to the raw blob, which is why
    # `git diff` never showed plaintext for a sops file anywhere and nobody noticed. And had it
    # re-exec'd with its own name it would have landed in the clean arm, which ENCRYPTS — the
    # opposite of what a textconv is for.
    exec <"${FILE}"
    exec "$(realpath "$0")" smudge "$FORMAT" "${@}"
    ;;
  *)
    exec "$(realpath "$0")" "$OP" "$FORMAT" "${@}"
    ;;
  esac

  # should never occur
  exit 1
elif [[ "${SCRIPT[name]}" = "sops.sh" ]]; then
  sops::generate_config
  exit $?
fi

# Exit if no stdin available.
# stdin is used to fed sops with the content to encrypt / decrypt.
test ! -t 0

# First arg passed to script.
# clean is meant to call sops encrypt
# smudge is meant to call sops decrypt
OP="${1}"
FORMAT="${2}"
FILE="${3}"

# Second arg passed to script
# The file name is fed to sops --filename-override so that sops can apply the creation_rules
# based on .sops.yaml file in the root of the repo.
declare -A META=(
  [filePath]="${FILE}"
  [fileName]="$(basename "${FILE}")"
  [fileExt]="${FILE##*.}"
  [fileFormat]="${FORMAT}"
)

if [[ -n "${META[fileFormat]}" && "${META[fileFormat]}" != "binary" ]]; then
  git::sops::anchors() {
    yq eval '
      select(documentIndex == 0) |
      .. | select(anchor | length > 0) | 
      [path | join("."), anchor] | join("|")
    ' /dev/stdin | while IFS='|' read -r path anchor; do
      # Skip empty lines
      if [ -z "$path" ] && [ -z "$anchor" ]; then
        continue
      fi

      IFS='.' read -ra parts <<<"$path"
      local depth=$((${#parts[@]} - 1))

      for ((i = 0; i < depth; i++)); do
        current=$(
          IFS='.'
          echo "${parts[*]:0:$((i + 1))}"
        )
        if [[ "$prev_path" != "$current"* ]]; then
          printf "%$((i * 2))s%s:\n" "" "${parts[i]}"
        fi
      done

      if [ ${#parts[@]} -gt 0 ]; then
        last_part="${parts[depth]}"
        printf "%$((depth * 2))s%s: &%s\n" "" "$last_part" "$anchor"
      else
        printf "P%s: &%s\n" "$path" "$anchor"
      fi

      prev_path="$path"
    done
  }

  git::sops::encrypt() {
    local input anchors encrypted
    input=$(cat)
    anchors=$(printf '%s' "$input" | git::sops::anchors)
    encrypted=$(printf '%s' "$input" | sops --encrypt --input-type=yaml --output-type=yaml --filename-override="${META[fileName]}" /dev/stdin)
  
    if [[ -n "$anchors" ]]; then
      printf '%s\n%s' "$encrypted" "$anchors" | yq --output-format=yaml eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' -
    else
      printf '%s' "$encrypted"
    fi
  }

  git::sops::decrypt() {
    sops --decrypt --input-type=yaml --output-type=yaml --filename-override="${META[fileName]}" /dev/stdin |
      yq --input-format=yaml --output-format="${META[fileFormat]}" eval . /dev/stdin
  }

  # The COMPARISON projection — NEVER a transform of what gets stored. Its only caller is the
  # idempotence check in the clean/textconv arm, and it must be applied to BOTH sides there: the
  # whole point is that two spellings of the same document project to one form.
  #
  # `--no-doc` drops the leading `---` and `sort_keys(..)` makes key order irrelevant, so a
  # producer's style stops deciding whether a secret "changed".
  git::sops::canonical() {
    yq --input-format=yaml --output-format="${META[fileFormat]}" --no-doc eval 'sort_keys(..)' /dev/stdin
  }
else
  git::sops::encrypt() {
    sops --encrypt --input-type=binary --output-type=binary --filename-override="${META[fileName]}" /dev/stdin
  }
  git::sops::decrypt() {
    sops --decrypt --input-type=binary --output-type=binary --filename-override="${META[fileName]}" /dev/stdin
  }

  # Binary has no structure to canonicalise — the bytes ARE the document, so the projection is
  # identity. Defined rather than special-cased at the call site, so the comparison below has ONE
  # shape for every format (the uniformity rule: no variant to remember).
  git::sops::canonical() {
    cat
  }
fi

case "${OP}" in
"smudge")
  # Decrypt the stdin blob. Capture it first so a non-sops blob can be passed through.
  INPUT="$(cat)"
  TMP=$(mktemp)
  decrypt_rc=0
  DECRYPTED=$(git::sops decrypt <<<"${INPUT}" 2>"$TMP") || decrypt_rc=$?
  err=$(cat "$TMP")
  rm "$TMP"
  wrong_key_error_message="age: no identity matched any of the recipients"
  metadata_missing="sops metadata not found"
  if [[ $err == *"${wrong_key_error_message}"* ]]; then
    # Host has no matching age identity — leave worktree empty rather than
    # writing stale ciphertext. Expected on machines without the key.
    :
  elif [[ $err == *"${metadata_missing}"* ]]; then
    # The blob at rest is NOT sops-encrypted (plaintext a prior non-required commit stored, or
    # one not yet cleaned) — nothing to decrypt, so pass it through as-is rather than abort the
    # checkout (which `required = true` would make fatal). The next stage re-encrypts via clean.
    git::sops show "${INPUT}"
  elif (( decrypt_rc != 0 )); then
    echo >&2 "sops smudge filter: decryption failed for ${META[filePath]} (rc=${decrypt_rc}): ${err}"
    exit "${decrypt_rc}"
  else
    git::sops show "${DECRYPTED}"
  fi
  ;;
"clean")
  # ⚠️ `textconv` USED to share this arm, which was wrong twice over: a textconv must render a blob
  # readable, and this arm ENCRYPTS. It now re-execs as smudge, so the label is gone rather than left
  # standing as an unreachable alternative.
  #
  # Either the file was not committed yet, or the existing decrypted content is different
  # from the input, in which case we output the new encrypted input.
  # If the file was commited and its decrypted content is the same as the new input,
  # output the old encrypted content.
  ENCRYPTED_HEAD_CONTENTS="$(git cat-file -p "HEAD:${META[filePath]}" 2>/dev/null || true)"
  # HEAD may NOT be sops-encrypted: a file first transitioning to sops, or one a prior
  # non-required commit stored unfiltered (plaintext) — decrypting it then fails "metadata not
  # found". Under `required = true` a non-zero here would abort EVERY git op on the file (status
  # wedged). Tolerate it: an undecryptable HEAD is treated as no comparable HEAD, so the input is
  # (re-)encrypted below rather than compared — which also transitions a leaked plaintext blob to
  # ciphertext on its next stage.
  DECRYPTED_HEAD_CONTENTS="$(git::sops decrypt <<<"${ENCRYPTED_HEAD_CONTENTS}" 2>/dev/null || true)"

  INPUT="$(cat /dev/stdin)"

  # ★ Both sides of the comparison go through the SAME canonical projection, or the idempotence this
  # arm promises never fires. Measured 2026-09-30 on rke2lab's rendered branch: the two sides
  # differed by exactly ONE line — a leading `---` the renderer emits and sops's own output does not
  # — so EVERY encrypted manifest was re-encrypted on EVERY render. That is not free: sops takes a
  # fresh AES-GCM IV, a fresh ephemeral age key per recipient and a `lastmodified` stamp each time,
  # so a re-encryption is ALWAYS a new blob. 28 Secrets churning per render, ~370 lines of
  # incompressible ciphertext, renders measured at `369 insertions(+), 369 deletions(-)` with
  # nothing whatsoever changed.
  #
  # ⚠️ `yq eval .` is NOT a canonicaliser — it faithfully preserves whether the input carried a
  # document separator, so normalising one side with it fixes nothing (verified: 0 of 29 matched).
  # The projection has to be canonical: `--no-doc` removes the separator, `sort_keys(..)` makes key
  # order irrelevant. With both sides projected, 26 of 29 match and stop churning; the rest differ
  # in real content, which is exactly what should still be re-encrypted.
  #
  # A one-sided projection is the classic asymmetric-comparison bug, and the discipline already
  # exists in this fleet: lock-envs normalises BOTH sides with `jq -S` before deciding a lock moved.
  # This projects for the COMPARISON only — what gets encrypted below is still the caller's INPUT
  # verbatim, so no producer's formatting is ever rewritten behind its back.
  HEAD_CANONICAL="$(git::sops canonical <<<"${DECRYPTED_HEAD_CONTENTS}" 2>/dev/null || true)"
  INPUT_CANONICAL="$(git::sops canonical <<<"${INPUT}" 2>/dev/null || true)"

  # An input that does not project — invalid YAML, or yq failing — must compare UNEQUAL and be
  # encrypted. Treating it as a match would stage the OLD blob for NEW content, which is the one
  # outcome worse than churn: a silent loss. So the emptiness of INPUT_CANONICAL is a condition to
  # re-encrypt, never a reason to skip.
  if [[ -z "${ENCRYPTED_HEAD_CONTENTS}" || -z "${INPUT_CANONICAL}" \
    || "${HEAD_CANONICAL}" != "${INPUT_CANONICAL}" ]]; then
    # Refuse to encrypt content that already looks encrypted — otherwise a
    # never-smudged worktree file gets passed through and sops exits non-zero,
    # which without this guard would silently stage empty output.
    if [[ "${META[fileFormat]}" != "binary" ]] \
        && printf '%s' "${INPUT}" | grep -qE '^sops:|^sops_version:'; then
      echo >&2 "sops ${OP} filter: ${META[filePath]} already contains sops metadata — worktree likely not smudged; refusing to stage."
      exit 1
    fi
    OUTPUT=$( git::sops encrypt <<<"${INPUT}" ) || {
      echo >&2 "sops ${OP} filter: encryption failed for ${META[filePath]} — refusing to stage."
      exit 1
    }
    if [[ -z "${OUTPUT}" ]]; then
      echo >&2 "sops ${OP} filter: produced empty output for ${META[filePath]} — refusing to stage."
      exit 1
    fi
  else
    OUTPUT="${ENCRYPTED_HEAD_CONTENTS}"
  fi
  git::sops show "${OUTPUT}"
  ;;
*)
  exit 1
  ;;
esac
