#!/usr/bin/env -S bash -exuo pipefail
# @codebase
# Load SSH keys listed in generated keys.yaml into the ssh-agent via keychain,
# and refresh the managed block of authorized_keys from corresponding .pub files.
# Key files are extracted by the Home Manager activation extractSSHKeys step.
# This script is run by the LaunchAgent on login to ensure keys survive reboots.

# shellcheck disable=SC1091
source "@bashTrampoline@"
# shellcheck disable=SC1091
source "@logger@"

if command -v logger >/dev/null 2>&1; then
  LOGGER_CMD="${LOGGER_CMD:-logger -t %TAG%}"
fi
activation_redirect_streams home-manager.ssh-add-keys

SSH_KEYS_YAML="${1:?SSH keys YAML file required}"
KEYS_DIR="$( dirname "$SSH_KEYS_YAML")"
AUTHORIZED_KEYS_FILE="${HOME}/.ssh/authorized_keys"
MARK_BEGIN="# >>> managed-by: ssh-add-keys BEGIN >>>"
MARK_END="# <<< managed-by: ssh-add-keys END <<<"

# Extract key names from YAML with underscores replaced by dashes
keyList=$(yq eval '.keys | keys[] | sub("_", "-")' "$SSH_KEYS_YAML")

# Ensure authorized_keys exists
if [[ ! -f "$AUTHORIZED_KEYS_FILE" ]]; then
  install -m 600 /dev/null "$AUTHORIZED_KEYS_FILE"
fi

if [[ -z "$keyList" ]]; then
  echo "No keys found in $SSH_KEYS_YAML; run home-manager activation first." >&2
  exit 0
fi

# Initialize / attach to agent (keychain handles reuse)
source <( keychain -q ${KEYCHAIN_FLAGS:---noask --nogui} --eval )

generatedTmp=$(mktemp)
trap 'rm -f "$generatedTmp" "$AUTHORIZED_KEYS_FILE.new" 2>/dev/null || true' EXIT

# Add each listed key to the agent; collect public keys for authorized_keys update
while IFS= read -r keyName; do
  [[ -n "$keyName" ]] || continue
  [[ "$keyName" == \#* ]] && continue
  keyPath="${KEYS_DIR}/${keyName}"
  [[ -f "$keyPath" ]] || { echo "Warning: key not found: $keyPath" >&2; continue; }

  ssh-add -q -d "$keyPath" 2>/dev/null || true
  ssh-add "$keyPath" 2>/dev/null || true

  pubPath="${keyPath}.pub"
  if [[ -f "$pubPath" ]]; then
    cat "$pubPath" >> "$generatedTmp"
  fi
done <<< "$keyList"

# Deduplicate gathered public keys
if [[ -s "$generatedTmp" ]]; then
  awk '!seen[$0]++' "$generatedTmp" > "$generatedTmp.dedup" && mv "$generatedTmp.dedup" "$generatedTmp"
fi

# Update authorized_keys managed block
existingTmp=$(mktemp)
trap 'rm -f "$existingTmp" 2>/dev/null || true' EXIT

if grep -q "${MARK_BEGIN}" "$AUTHORIZED_KEYS_FILE"; then
  awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" 'BEGIN{skip=0} {
    if ($0==b){skip=1; next} if ($0==e){skip=0; next} if (!skip) print $0
  }' "$AUTHORIZED_KEYS_FILE" > "$existingTmp"
else
  cat "$AUTHORIZED_KEYS_FILE" > "$existingTmp"
fi

{
  cat "$existingTmp"
  echo "$MARK_BEGIN"
  echo "# Managed public keys from: $SSH_KEYS_YAML"
  if [[ -s "$generatedTmp" ]]; then
    cat "$generatedTmp"
  else
    echo "# (none)"
  fi
  echo "$MARK_END"
} > "$AUTHORIZED_KEYS_FILE.new"

mv "$AUTHORIZED_KEYS_FILE.new" "$AUTHORIZED_KEYS_FILE"
chmod 600 "$AUTHORIZED_KEYS_FILE"

exit 0
