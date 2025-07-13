#!/run/current-system/sw/bin/env -S bash -euo pipefail
# -*- mode: sh -*-

test -n "${GIT_TRACE:-}" && set -x

sops::config() {
  local fmt=${1}
  local name=sops-${fmt}

  cat <<EOF >sops.d/$fmt
[filter "$name"]
  clean = /Users/stephane.lacoin/.config/git/sops.d/$fmt-clean %f
  smudge = /Users/stephane.lacoin/.config/git/sops.d/$fmt-smudge %f
[diff "$name"]
  textconv = /Users/stephane.lacoin/.config/git/sops.d/$fmt-textconv
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

  xdg.configFile."git/sops.d" = {
    source = pkgs.stdenvNoCC.mkDerivation {
      name = "sops-filtered-config";
      src = ./sops.d;
      
      # Ensure rsync is available for the build
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
    source = pkgs.substituteAll {
      src = ./sops;
      sopsConfigHome = "\${config.xdg.configHome}/git/sops.d";
    };
  };

$(for fmt in "${formats[@]}"; do
    cat <<EOL

  xdg.configFile."git/sops.d/$fmt" = {
    source = pkgs.substituteAll {
      src = ./sops.d/$fmt;
      sopsConfigHome = "\${config.xdg.configHome}/git/sops.d";
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
  decrypt | encrypt)
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
  # Do not run if no .sops.yaml in repository
  test -r .sops.yaml || {
    echo >&2 "You do not have configured sops for that repository. You're missing $(pwd)/.sops.yaml."
    exit 1
  }

  # Exit if the file names were not given
  test $# -ge 1

  OP=${SCRIPT[name]##*-}       # Extract operation from script name
  FORMAT=${SCRIPT[name]%%[-]*} # Extract format from script name
  FILE="$1"                    # First argument as file

  case "$OP" in
  "textconv")
    exec <"${FILE}"
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
else
  git::sops::encrypt() {
    sops --encrypt --input-type=binary --output-type=binary --filename-override="${META[fileName]}" /dev/stdin
  }
  git::sops::decrypt() {
    sops --decrypt --input-type=binary --output-type=binary --filename-override="${META[fileName]}" /dev/stdin
  }
fi

case "${OP}" in
"smudge")
  # Just decrypt the stdin contents.
  TMP=$(mktemp)
  DECRYPTED=$(git::sops decrypt </dev/stdin 2>"$TMP")
  err=$(cat "$TMP")
  rm "$TMP"
  wrong_key_error_message="age: no identity matched any of the recipients"
  if [[ $err == *"${wrong_key_error_message}"* ]]; then
    :
  else
    git::sops show "${DECRYPTED}"
  fi
  ;;
"textconv" | "clean")
  # Either the file was not committed yet, or the existing decrypted content is different
  # from the input, in which case we output the new encrypted input.
  # If the file was commited and its decrypted content is the same as the new input,
  # output the old encrypted content.
  ENCRYPTED_HEAD_CONTENTS="$(git cat-file -p "HEAD:${META[filePath]}" 2>/dev/null || true)"
  DECRYPTED_HEAD_CONTENTS="$(git::sops decrypt <<<"${ENCRYPTED_HEAD_CONTENTS}")"

  INPUT="$(cat /dev/stdin)"

  if [[ -z "${ENCRYPTED_HEAD_CONTENTS}" || "${DECRYPTED_HEAD_CONTENTS}" != "${INPUT}" ]]; then
    OUTPUT=$( git::sops encrypt <<<"${INPUT}" )
  else
    OUTPUT="${ENCRYPTED_HEAD_CONTENTS}"
  fi
  git::sops show "${OUTPUT}"
  ;;
*)
  exit 1
  ;;
esac
