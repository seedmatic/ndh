#!/usr/bin/env bash
# @codebase
# One-time/occasional enrollment helper:
#   Capture current VM ssh_host_ed25519 keypair and persist it into the encrypted
#   repo secrets profile so subsequent bootstraps can distribute a stable host key.
set -euo pipefail

: "${COPILOT_XTRACE:=1}"
if [[ "${COPILOT_XTRACE}" == "1" ]]; then
  export BASH_XTRACEFD=2
  export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
fi

usage() {
  cat <<'EOF'
Usage: enroll-vm-hostkey-into-sops.sh [options]

Options:
  --vm <name>             Lima instance name (default: nerd-nixos)
  --guest <name>          Guest key suffix for vz-guest-<name> (default: nixos)
  --key-name <name>       Explicit key entry name under .profiles.<profile>
  --profile <name>        Secrets profile under .profiles (default: committed)
  --secrets-file <path>   Encrypted SOPS YAML file (default: modules/home-manager/ssh.d/keys.yaml)
  --repo-root <path>      Repo root (default: git top-level)
  --dry-run               Capture/validate only; do not write secrets
  -h, --help              Show this help

Behavior:
  1) Reads /etc/ssh/ssh_host_ed25519_key(.pub) from the guest via limactl shell
  2) Validates private/public consistency
  3) Decrypts the encrypted worktree secrets file (source of truth)
  4) Updates .profiles.<profile>.<key-name>.{private,public}
  5) Re-encrypts and writes back atomically to the worktree secrets file

Notes:
  - Designed for bootstrap enrollment workflow.
  - Safe to re-run; updates host key material idempotently.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 127
  }
}

VM_NAME="nerd-nixos"
GUEST_NAME="nixos"
KEY_NAME=""
PROFILE_NAME="committed"
SECRETS_FILE="modules/home-manager/ssh.d/keys.yaml"
REPO_ROOT=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)
      shift; VM_NAME="${1:-}" ;;
    --guest)
      shift; GUEST_NAME="${1:-}" ;;
    --key-name)
      shift; KEY_NAME="${1:-}" ;;
    --profile)
      shift; PROFILE_NAME="${1:-}" ;;
    --secrets-file)
      shift; SECRETS_FILE="${1:-}" ;;
    --repo-root)
      shift; REPO_ROOT="${1:-}" ;;
    --dry-run)
      DRY_RUN=1 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      usage
      exit 2 ;;
  esac
  shift || true
done

if [[ -z "${KEY_NAME}" ]]; then
  KEY_NAME="vz-guest-${GUEST_NAME}"
fi

require_cmd limactl
require_cmd sops
require_cmd yq
require_cmd ssh-keygen
require_cmd mktemp

if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [[ -z "$REPO_ROOT" ]]; then
  echo "ERROR: unable to determine repo root. Use --repo-root <path>." >&2
  exit 2
fi

cd "$REPO_ROOT"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: secrets file not found: $REPO_ROOT/$SECRETS_FILE" >&2
  exit 2
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

guest_priv="$workdir/ssh_host_ed25519_key"
guest_pub="$workdir/ssh_host_ed25519_key.pub"
plain_yaml="$workdir/secrets.plain.yaml"
updated_yaml="$workdir/secrets.updated.yaml"
meta_json="$workdir/enrollment-meta.json"

printf '[enroll] capturing host key from VM=%s\n' "$VM_NAME"
limactl shell "$VM_NAME" -- sudo cat /etc/ssh/ssh_host_ed25519_key > "$guest_priv"
limactl shell "$VM_NAME" -- sudo cat /etc/ssh/ssh_host_ed25519_key.pub > "$guest_pub"
chmod 600 "$guest_priv"
chmod 644 "$guest_pub"

if [[ ! -s "$guest_priv" || ! -s "$guest_pub" ]]; then
  echo "ERROR: captured host key material is empty" >&2
  exit 1
fi

# Validate keypair consistency
calc_pub="$workdir/derived.pub"
ssh-keygen -y -f "$guest_priv" > "$calc_pub"
if ! cmp -s "$calc_pub" "$guest_pub"; then
  echo "ERROR: private/public key mismatch from guest capture" >&2
  exit 1
fi

fingerprint="$(ssh-keygen -lf "$guest_pub" | awk '{print $2}')"
printf '[enroll] captured fingerprint: %s\n' "$fingerprint"

host_pub_type="$(awk '{print $1}' "$guest_pub")"
host_pub_base64="$(awk '{print $2}' "$guest_pub")"
host_pub_comment="$(awk '{if (NF > 2) { $1=""; $2=""; sub(/^  */, ""); print } }' "$guest_pub")"

if [[ -z "$host_pub_type" || -z "$host_pub_base64" ]]; then
  echo "ERROR: unable to parse host public key into canonical fields (type/public/comment)" >&2
  exit 1
fi

# Decrypt secrets and verify profile path exists.
# Encrypted worktree file is the canonical source of truth.
sops -d --input-type yaml --output-type yaml --filename-override "$(basename "$SECRETS_FILE")" "$SECRETS_FILE" > "$plain_yaml"
printf '[enroll] baseline source: encrypted worktree file (%s)\n' "$SECRETS_FILE"

profile_type="$(yq eval ".profiles.\"$PROFILE_NAME\" | type" "$plain_yaml" 2>/dev/null || true)"
if [[ "$profile_type" != "!!map" ]]; then
  echo "ERROR: profile not found in secrets: .profiles.\"$PROFILE_NAME\"" >&2
  exit 1
fi

key_node_type="$(yq eval ".profiles.\"$PROFILE_NAME\".\"$KEY_NAME\" | type" "$plain_yaml" 2>/dev/null || true)"
if [[ "$key_node_type" != "!!map" ]]; then
  echo "ERROR: key entry .profiles.\"$PROFILE_NAME\".\"$KEY_NAME\" is missing or not a map." >&2
  echo "Refusing to create a new key entry automatically because comment-based SOPS encryption markers must be pre-seeded." >&2
  exit 1
fi

existing_private="$(yq -r ".profiles.\"$PROFILE_NAME\".\"$KEY_NAME\".private // \"\"" "$plain_yaml")"
if [[ -z "$existing_private" ]]; then
  echo "ERROR: key entry .profiles.\"$PROFILE_NAME\".\"$KEY_NAME\".private is empty." >&2
  echo "Refusing to write private key material without a pre-seeded encrypted field/marker." >&2
  exit 1
fi

export HOST_PRIV_CONTENT
HOST_PRIV_CONTENT="$(cat "$guest_priv")"
export HOST_PUB_TYPE
HOST_PUB_TYPE="$host_pub_type"
export HOST_PUB_BASE64
HOST_PUB_BASE64="$host_pub_base64"
export HOST_PUB_COMMENT
HOST_PUB_COMMENT="$host_pub_comment"

cp "$plain_yaml" "$updated_yaml"
yq -i ".profiles.\"$PROFILE_NAME\".\"$KEY_NAME\".private = strenv(HOST_PRIV_CONTENT)" "$updated_yaml"
yq -i ".profiles.\"$PROFILE_NAME\".\"$KEY_NAME\".type = strenv(HOST_PUB_TYPE)" "$updated_yaml"
yq -i ".profiles.\"$PROFILE_NAME\".\"$KEY_NAME\".public = strenv(HOST_PUB_BASE64)" "$updated_yaml"
yq -i ".profiles.\"$PROFILE_NAME\".\"$KEY_NAME\".comment = strenv(HOST_PUB_COMMENT)" "$updated_yaml"

# Optional metadata breadcrumbs for auditability
now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
yq -i ".profiles.\"$PROFILE_NAME\".\"$KEY_NAME\".enrollment = {\"fingerprint\": \"$fingerprint\", \"source\": \"$VM_NAME\", \"capturedAt\": \"$now_utc\"}" "$updated_yaml"

printf '{"vm":"%s","profile":"%s","keyName":"%s","fingerprint":"%s","capturedAt":"%s"}\n' \
  "$VM_NAME" "$PROFILE_NAME" "$KEY_NAME" "$fingerprint" "$now_utc" > "$meta_json"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[enroll] dry-run complete; no secrets written"
  cat "$meta_json"
  exit 0
fi

# Re-encrypt back to the configured secrets file
sops --encrypt --input-type yaml --output-type yaml --filename-override "$(basename "$SECRETS_FILE")" "$updated_yaml" > "$SECRETS_FILE"

state_dir="$REPO_ROOT/.local.d/share"
mkdir -p "$state_dir"
cp "$meta_json" "$state_dir/hostkey-enrollment-${VM_NAME}.json"

printf '[enroll] updated %s (profile=%s, key=%s, vm=%s)\n' "$SECRETS_FILE" "$PROFILE_NAME" "$KEY_NAME" "$VM_NAME"
printf '[enroll] state marker: %s\n' "$state_dir/hostkey-enrollment-${VM_NAME}.json"
