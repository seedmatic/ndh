#!/usr/bin/env bash
set -euo pipefail

LIMA_VM_NAME="@dollar@{LIMA_VM_NAME:-nerd-nixos}"
LIMA_USER="@dollar@{LIMA_USER:-@profileUser@}"
LIMA_IDENTITY_FILE="$HOME/.lima/_config/user"

: Check if Lima VM is running
if ! @limaBin@ list "$LIMA_VM_NAME" --format=yaml | @yqBin@ -e '.instance.status == "Running"' >/dev/null 2>&1; then
  cat <<EoMessage >&2
Lima VM '$LIMA_VM_NAME' is not running - using local Podman
EoMessage
  cat <<EOF
[engine]
remote = false
EOF
  exit 0
fi

: Get VM SSH connection details
SSH_HOST=$(@limaBin@ list "$LIMA_VM_NAME" --format=yaml | @yqBin@ '.instance.sshAddress')
SSH_PORT=$(@limaBin@ list "$LIMA_VM_NAME" --format=yaml | @yqBin@ '.instance.sshLocalPort')

cat <<EOF
[engine]
remote = true

[engine.service_destinations]
[engine.service_destinations.lima-$LIMA_VM_NAME]
uri = "ssh://$LIMA_USER@$SSH_HOST:$SSH_PORT/run/podman/podman.sock"
identity = "$LIMA_IDENTITY_FILE"
default = true
EOF
