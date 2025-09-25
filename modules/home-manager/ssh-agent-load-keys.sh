#!/usr/bin/env -S bash -exuo pipefail
# @codebase
# Extract private keys from the consolidated YAML (keys.yaml) and load them into an ssh-agent via keychain.
# Externalized from inline definition in ssh-add-keys.nix for clarity and easier maintenance.

KEYS_FILE="$1"
AUTHORIZED_KEYS_FILE="${HOME}/.ssh/authorized_keys"
MARK_BEGIN="# >>> managed-by: ssh-add-keys BEGIN >>>"
MARK_END="# <<< managed-by: ssh-add-keys END <<<"

if [[ -z "$KEYS_FILE" ]]; then
  echo "Usage: $0 <keys.yaml>" >&2
  exit 64
fi

if [[ ! -f "$KEYS_FILE" ]]; then
  echo "SSH keys YAML file not found: $KEYS_FILE" >&2
  exit 1
fi

# Ensure authorized_keys exists (paranoid double-check; activation should have done this)
if [[ ! -f "$AUTHORIZED_KEYS_FILE" ]]; then
  install -m 600 /dev/null "$AUTHORIZED_KEYS_FILE"
fi

# Initialize / attach to agent (keychain handles reuse)
eval "$(keychain -q ${KEYCHAIN_FLAGS:---noask --nogui} --agents ssh --eval)"

:
# Collect generated public keys (deduplicated) into a temporary file (managed block assembly later).
generatedTmp=$(mktemp)
trap 'rm -f "$generatedTmp" "$AUTHORIZED_KEYS_FILE.tmp" "$AUTHORIZED_KEYS_FILE.new" 2>/dev/null || true' EXIT

## Always use yq shell output (simpler & faster)
# Load all keys.* variables: keys_<name>_public / keys_<name>_private / keys_<name>_usage_<n>
# Use process substitution + source instead of eval $(...) to avoid additional quoting expansion tiers.
# shellcheck disable=SC1090
source <( yq -o shell '.' "$KEYS_FILE" )

# Build arrays of bases and usages in a single scan
declare -A KEY_PUBLIC KEY_PRIVATE KEY_USAGES
while IFS= read -r var; do
  case "$var" in
    keys_*_public)
      base="${var#keys_}"; base="${base%_public}"; KEY_PUBLIC["$base"]="${!var}" ;;
    keys_*_private)
      base="${var#keys_}"; base="${base%_private}"; KEY_PRIVATE["$base"]="${!var}" ;;
    keys_*_usage_[0-9]*)
      # usage vars: accumulate
      tmp="${var#keys_}"; tmp="${tmp%_usage_*}"; base="$tmp"; KEY_USAGES["$base"]+=" ${!var}" ;;
  esac
done < <( compgen -A variable | grep '^keys_' )

for base in "${!KEY_PUBLIC[@]}"; do
  pubLine="${KEY_PUBLIC[$base]}"
  privBlock="${KEY_PRIVATE[$base]:-}"
  usagesStr="${KEY_USAGES[$base]:-}"
  include_in_authorized=0
  for u in $usagesStr; do
    case "$u" in
      ssh-user|user-signing) include_in_authorized=1 ;;
    esac
  done
  if [[ -n "$privBlock" && "$privBlock" == *"BEGIN OPENSSH PRIVATE KEY"* ]]; then
    printf '%s\n' "$privBlock" | ssh-add - 2>/dev/null || true
  fi
  pubLineTrimmed="${pubLine%%[[:space:]]}"
  if [[ $include_in_authorized -eq 1 && "$pubLineTrimmed" =~ ^ssh-(ed25519|rsa|ecdsa|dss)\  ]]; then
    printf '%s\n' "$pubLineTrimmed" >> "$generatedTmp"
  fi
done

# Deduplicate generated keys (if any)
if [[ -s "$generatedTmp" ]]; then
  awk '!seen[$0]++' "$generatedTmp" > "$generatedTmp.dedup" && mv "$generatedTmp.dedup" "$generatedTmp"
fi

# Read existing authorized_keys content excluding any previous managed block
existingTmp=$(mktemp)
trap 'rm -f "$existingTmp" "$existingTmp.filtered" 2>/dev/null || true' RETURN

if grep -q "${MARK_BEGIN}" "$AUTHORIZED_KEYS_FILE"; then
  # Remove old managed block
  awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" 'BEGIN{skip=0} {
    if ($0==b){skip=1; next} if ($0==e){skip=0; next} if (!skip) print $0
  }' "$AUTHORIZED_KEYS_FILE" > "$existingTmp"
else
  cat "$AUTHORIZED_KEYS_FILE" > "$existingTmp"
fi

# Assemble new file
{
  cat "$existingTmp"
  echo "$MARK_BEGIN"
  echo "# Managed public keys extracted from: $KEYS_FILE"
  if [[ -s "$generatedTmp" ]]; then
    cat "$generatedTmp"
  else
    echo "# (none)"
  fi
  echo "$MARK_END"
} > "$AUTHORIZED_KEYS_FILE.new"

mv "$AUTHORIZED_KEYS_FILE.new" "$AUTHORIZED_KEYS_FILE"
chmod 600 "$AUTHORIZED_KEYS_FILE"

unset existingTmp


exit 0
