#!/usr/bin/env bash
# @codebase
# Idempotent VM host-key sync helper:
# - verifies VM host key against encrypted SOPS profile entry
# - enrolls/updates encrypted keys.yaml only when mismatched (or forced)
# - verifies again after update and checks decrypt integrity
set -euo pipefail

: "${COPILOT_XTRACE:=1}"
if [[ "${COPILOT_XTRACE}" == "1" ]]; then
  export BASH_XTRACEFD=2
  export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
fi

usage() {
  cat <<'EOF'
Usage: sync-vm-hostkey-keys-yaml.sh [options]

Options:
  --vm <name>             Lima instance name (default: nerd-nixos)
  --guest <name>          Guest suffix for vz-guest-<name> (default: nixos)
  --key-name <name>       Explicit key name (default: vz-guest-<guest>)
  --profile <name>        Secrets profile name (default: committed)
  --secrets-file <path>   Encrypted SOPS YAML (default: modules/home-manager/ssh.d/keys.yaml)
  --repo-root <path>      Repository root (default: git top-level)
  --force                 Force enrollment even if verify already passes
  -h, --help              Show this help

Behavior:
  1) Runs verify-vm-hostkey-from-sops.sh
  2) If mismatch (or --force), runs enroll-vm-hostkey-into-sops.sh
  3) Verifies again and checks SOPS decrypt integrity
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command: $1" >&2
    exit 127
  }
}

VM_NAME="nerd-nixos"
GUEST_NAME="nixos"
KEY_NAME=""
PROFILE_NAME="committed"
SECRETS_FILE="modules/home-manager/ssh.d/keys.yaml"
REPO_ROOT=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) shift; VM_NAME="${1:-}" ;;
    --guest) shift; GUEST_NAME="${1:-}" ;;
    --key-name) shift; KEY_NAME="${1:-}" ;;
    --profile) shift; PROFILE_NAME="${1:-}" ;;
    --secrets-file) shift; SECRETS_FILE="${1:-}" ;;
    --repo-root) shift; REPO_ROOT="${1:-}" ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
  shift || true
done

if [[ -z "${KEY_NAME}" ]]; then
  KEY_NAME="vz-guest-${GUEST_NAME}"
fi

require_cmd git
require_cmd sops

if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
fi
[[ -n "$REPO_ROOT" ]] || { echo "ERROR: cannot determine repo root" >&2; exit 2; }
cd "$REPO_ROOT"

enroll_script="$REPO_ROOT/modules/nixos/ssh-keys.d/enroll-vm-hostkey-into-sops.sh"
verify_script="$REPO_ROOT/modules/nixos/ssh-keys.d/verify-vm-hostkey-from-sops.sh"

[[ -x "$enroll_script" ]] || { echo "ERROR: missing executable enroll script: $enroll_script" >&2; exit 2; }
[[ -x "$verify_script" ]] || { echo "ERROR: missing executable verify script: $verify_script" >&2; exit 2; }
[[ -f "$SECRETS_FILE" ]] || { echo "ERROR: secrets file not found: $SECRETS_FILE" >&2; exit 2; }

verify_args=(
  --vm "$VM_NAME"
  --guest "$GUEST_NAME"
  --key-name "$KEY_NAME"
  --profile "$PROFILE_NAME"
  --secrets-file "$SECRETS_FILE"
  --repo-root "$REPO_ROOT"
)

enroll_args=(
  --vm "$VM_NAME"
  --guest "$GUEST_NAME"
  --key-name "$KEY_NAME"
  --profile "$PROFILE_NAME"
  --secrets-file "$SECRETS_FILE"
  --repo-root "$REPO_ROOT"
)

needs_enroll=1
if "$verify_script" "${verify_args[@]}"; then
  needs_enroll=0
fi

if [[ "$FORCE" -eq 1 ]]; then
  needs_enroll=1
fi

if [[ "$needs_enroll" -eq 1 ]]; then
  "$enroll_script" "${enroll_args[@]}"
else
  echo "[sync] already aligned: VM host key matches SOPS entry ($KEY_NAME)"
fi

"$verify_script" "${verify_args[@]}"

# Explicit decrypt integrity check for encrypted source-of-truth file.
sops -d --input-type yaml --output-type yaml --filename-override "$(basename "$SECRETS_FILE")" "$SECRETS_FILE" >/dev/null
echo "[sync] FINAL_DECRYPT_OK"

# Helpful output for follow-up review/commit.
git --no-pager status --short -- "$SECRETS_FILE"
git --no-pager diff -- "$SECRETS_FILE" | sed -n '1,120p'
