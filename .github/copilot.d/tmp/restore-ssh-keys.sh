#!/usr/bin/env bash
# @codebase - restore ssh-keys.d using the fixed extraction pipeline
set -euo pipefail

KEYS_YAML=/run/secrets/nix-darwin-home/nxmatic-ssh-keys.yaml
PROFILE=committed
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ssh-keys.d"
REPO=/private/var/lib/git/nxmatic/nix-darwin-home

if [[ ! -f "$KEYS_YAML" ]]; then
  echo "ERROR: $KEYS_YAML not found (sops not yet run?)" >&2
  exit 1
fi

tmp_keys=$(mktemp -d)
tmp_profile=$(mktemp)
trap 'rm -rf "$tmp_keys" "$tmp_profile"' EXIT

echo "=== Extracting profile: $PROFILE ==="
yq eval ".profiles.\"${PROFILE}\"" "$KEYS_YAML" > "$tmp_profile"

echo "=== Generating agent-keys manifest ==="
yq eval -r '
  to_entries[]
  | select(
      ((.value.usage // []) | join(",") | test("(^|,)(agent-signing|user-signing|ssh-user)(,|$)"))
      or
      (((.value.authorities // {}) | to_entries | map((.value.usage // []) | join(",")) | join(","))
        | test("(^|,)(ssh-user)(,|$)"))
    )
  | .key
' "$tmp_profile" | tee "$tmp_keys/agent-keys"

echo ""
echo "=== Extracting key files ==="
bash "${REPO}/modules/home-manager/ssh-extract-keys.sh" "$tmp_profile" "$tmp_keys"

echo ""
echo "=== Files produced ==="
ls -la "$tmp_keys"

echo ""
echo "=== Syncing to $STATE_DIR ==="
install -d -m 700 "$STATE_DIR"
rsync -avL \
  --checksum \
  --delete \
  --chmod=u+w,go-r \
  --chown="$(id -un):$(id -gn)" \
  "$tmp_keys"/ "$STATE_DIR"/

echo ""
echo "=== State dir after sync ==="
ls -la "$STATE_DIR"

echo ""
echo "=== Loading keys into agent ==="
if [[ -s "$STATE_DIR/agent-keys" ]]; then
  while IFS= read -r keyName; do
    [[ -n "$keyName" ]] || continue
    keyPath="$STATE_DIR/$keyName"
    if [[ -f "$keyPath" ]]; then
      ssh-add -q -d "$keyPath" 2>/dev/null || true
      ssh-add "$keyPath" 2>/dev/null && echo "  + loaded: $keyName" || echo "  ! failed: $keyName"
    else
      echo "  ? missing: $keyPath"
    fi
  done < "$STATE_DIR/agent-keys"
fi

echo ""
echo "=== Agent contents ==="
ssh-add -l 2>/dev/null || echo "(no agent or no keys)"

echo ""
echo "DONE. Try: ssh bioskop-nixos.local whoami"
