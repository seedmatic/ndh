#!/usr/bin/env bash
# @codebase
# Verify that the currently running VM host key matches the key stored in SOPS.
# Useful before re-enabling strict host-key checks.
set -euo pipefail

: "${COPILOT_XTRACE:=1}"
if [[ "${COPILOT_XTRACE}" == "1" ]]; then
  export BASH_XTRACEFD=2
  export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
fi

usage() {
  cat <<'EOF'
Usage: verify-vm-hostkey-from-sops.sh [options]

Options:
  --vm <name>             Lima instance (default: nerd-nixos)
  --guest <name>          Guest key suffix for vz-guest-<name> (default: nixos)
  --key-name <name>       Explicit top-level key entry name in the secrets YAML
  --secrets-file <path>   Encrypted SOPS file (default: modules/home-manager/ssh.d/keys.yaml)
  --repo-root <path>      Repo root (default: git top-level)
  -h, --help              Show help
EOF
}

VM_NAME="nerd-nixos"
GUEST_NAME="nixos"
KEY_NAME=""
SECRETS_FILE="modules/home-manager/ssh.d/keys.yaml"
REPO_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) shift; VM_NAME="${1:-}" ;;
    --guest) shift; GUEST_NAME="${1:-}" ;;
    --key-name) shift; KEY_NAME="${1:-}" ;;
    --secrets-file) shift; SECRETS_FILE="${1:-}" ;;
    --repo-root) shift; REPO_ROOT="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
  shift || true
done

if [[ -z "${KEY_NAME}" ]]; then
  KEY_NAME="vz-guest-${GUEST_NAME}"
fi

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 127; }; }
require_cmd limactl
require_cmd sops
require_cmd yq
require_cmd ssh-keygen

if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
fi
[[ -n "$REPO_ROOT" ]] || { echo "ERROR: cannot determine repo root" >&2; exit 2; }
cd "$REPO_ROOT"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

vm_pub="$workdir/vm_host.pub"
sops_plain="$workdir/secrets.plain.yaml"
sops_pub="$workdir/sops_host.pub"
sops_key_type=""
sops_key_public=""
sops_key_comment=""

limactl shell "$VM_NAME" -- sudo cat /etc/ssh/ssh_host_ed25519_key.pub > "$vm_pub"

sops -d --input-type yaml --output-type yaml --filename-override "$(basename "$SECRETS_FILE")" "$SECRETS_FILE" > "$sops_plain"
sops_key_type="$(yq -r ".\"$KEY_NAME\".type // \"\"" "$sops_plain")"
sops_key_public="$(yq -r ".\"$KEY_NAME\".public // \"\"" "$sops_plain")"
sops_key_comment="$(yq -r ".\"$KEY_NAME\".comment // \"\"" "$sops_plain")"

if [[ -n "$sops_key_type" && -n "$sops_key_public" ]]; then
  if [[ -n "$sops_key_comment" ]]; then
    printf '%s %s %s\n' "$sops_key_type" "$sops_key_public" "$sops_key_comment" > "$sops_pub"
  else
    printf '%s %s\n' "$sops_key_type" "$sops_key_public" > "$sops_pub"
  fi
fi

if [[ ! -s "$sops_pub" ]]; then
  echo "ERROR: missing canonical key fields under .\"$KEY_NAME\" in $SECRETS_FILE (need .type and .public)" >&2
  exit 1
fi

vm_fp="$(ssh-keygen -lf "$vm_pub" | awk '{print $2}')"
sops_fp="$(ssh-keygen -lf "$sops_pub" | awk '{print $2}')"

echo "VM fingerprint:    $vm_fp"
echo "SOPS fingerprint:  $sops_fp"
echo "Key name:          $KEY_NAME"

if [[ "$vm_fp" == "$sops_fp" ]]; then
  echo "OK: VM host key matches SOPS entry '$KEY_NAME'"
  exit 0
fi

echo "MISMATCH: VM host key differs from SOPS entry '$KEY_NAME'" >&2
exit 1
