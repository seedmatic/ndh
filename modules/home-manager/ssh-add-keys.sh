#!/usr/bin/env -S bash -exuo pipefail
# @codebase
# Extract private keys from the consolidated YAML (keys.yaml) and load them into an ssh-agent via keychain.
# Externalized from inline definition in ssh-add-keys.nix for clarity and easier maintenance.

KEYS_FILE="$1"
AUTHORIZED_KEYS_FILE="${HOME}/.ssh/authorized_keys"
KEYS_DIR="${HOME}/.ssh/keys.d"
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

# Ensure private key destination directory exists
install -d -m 700 "$KEYS_DIR"

# Initialize / attach to agent (keychain handles reuse)
source <( keychain -q ${KEYCHAIN_FLAGS:---noask --nogui} --eval )

:
# Collect generated public keys (deduplicated) into a temporary file (managed block assembly later).
generatedTmp=$(mktemp)
trap 'rm -f "$generatedTmp" "$AUTHORIZED_KEYS_FILE.tmp" "$AUTHORIZED_KEYS_FILE.new" 2>/dev/null || true' EXIT

## Always use yq shell output (simpler & faster)
# Load flattened shell variables emitted by yq (e.g., profiles_committed_*).
# Use process substitution + source instead of eval $(...) to avoid additional quoting expansion tiers.
# shellcheck disable=SC1090
source <( yq -o shell '.' "$KEYS_FILE" )

# Build arrays of bases and usages in a single scan
declare -A KEY_PUBLIC KEY_PRIVATE KEY_TYPE KEY_COMMENT KEY_USAGES
while IFS= read -r var; do
  case "$var" in
    *_public)
      base="${var%_public}"; KEY_PUBLIC["$base"]="${!var}" ;;
    *_private)
      base="${var%_private}"; KEY_PRIVATE["$base"]="${!var}" ;;
    *_type)
      base="${var%_type}"; KEY_TYPE["$base"]="${!var}" ;;
    *_comment)
      base="${var%_comment}"; KEY_COMMENT["$base"]="${!var}" ;;
    *_usage_[0-9]*)
      # usage vars: accumulate
      base="${var%_usage_*}"; KEY_USAGES["$base"]+=" ${!var}" ;;
  esac
done < <( compgen -A variable | grep -E '_(public|private|type|comment|usage_[0-9]+)$' )

for base in "${!KEY_PRIVATE[@]}"; do
  pubRaw="${KEY_PUBLIC[$base]:-}"
  pubType="${KEY_TYPE[$base]:-}"
  pubComment="${KEY_COMMENT[$base]:-}"
  if [[ "$pubRaw" =~ ^ssh-(ed25519|rsa|ecdsa|dss)\  ]]; then
    pubLine="$pubRaw"
  elif [[ -n "$pubType" && -n "$pubRaw" ]]; then
    pubLine="$pubType $pubRaw"
    if [[ -n "$pubComment" ]]; then
      pubLine+=" $pubComment"
    fi
  else
    pubLine="$pubRaw"
  fi
  pubLine="${pubLine%%[[:space:]]}"
  privBlock="${KEY_PRIVATE[$base]:-}"
  usagesStr="${KEY_USAGES[$base]:-}"
  include_in_authorized=0
  for u in $usagesStr; do
    case "$u" in
      ssh-user|user-signing) include_in_authorized=1 ;;
    esac
  done
  if [[ -n "$privBlock" && "$privBlock" == *"BEGIN OPENSSH PRIVATE KEY"* ]]; then
    fileBase="${base//_/-}"
    keyPath="${KEYS_DIR}/${fileBase}"
    # If the on-disk key doesn't match the YAML public key (or is missing), rewrite it from YAML
    yamlB64=$(printf '%s\n' "$pubLine" | awk '{print $2}')
    if [[ -z "$yamlB64" && -n "$pubRaw" ]]; then
      yamlB64="$pubRaw"
    fi
    fileB64=$(ssh-keygen -y -f "$keyPath" 2>/dev/null | awk '{print $2}' || true)
    if [[ ! -f "$keyPath" || -z "$fileB64" || ( -n "$yamlB64" && "$yamlB64" != "$fileB64" ) ]]; then
      printf '%s\n' "$privBlock" > "$keyPath"
      chmod 600 "$keyPath"
    fi

    ssh-add -q -d "$keyPath" 2>/dev/null || true
    ssh-add "$keyPath" 2>/dev/null || true
  fi
  if [[ $include_in_authorized -eq 1 && "$pubLine" =~ ^ssh-(ed25519|rsa|ecdsa|dss)\  ]]; then
    printf '%s\n' "$pubLine" >> "$generatedTmp"
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
