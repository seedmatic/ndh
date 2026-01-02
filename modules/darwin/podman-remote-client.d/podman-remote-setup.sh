#!/usr/bin/env bash
set -euo pipefail

LIMA_VM_NAME="@dollar@{LIMA_VM_NAME:-nerd-nixos}"
LIMA_CONTEXT_NAME="lima-@dollar@{LIMA_VM_NAME}"
LIMA_USER="@dollar@{LIMA_USER:-@profileUser@}"
LIMA_IDENTITY_FILE="$HOME/.lima/_config/user"
LIMA_SSH_HOST="$LIMA_CONTEXT_NAME"

: Create containers config directory
mkdir -p "$HOME/.config/containers"

: Generate and install containers.conf
@generateContainersConf@ > "$HOME/.config/containers/containers.conf"

: Create Docker context for Lima VM
@dockerBin@ context rm -f $LIMA_CONTEXT_NAME 2>/dev/null
@dockerBin@ context create $LIMA_CONTEXT_NAME \
  --description "Lima $LIMA_VM_NAME Podman via SSH" \
  --docker "host=ssh://$LIMA_SSH_HOST"
@dockerBin@ context use $LIMA_CONTEXT_NAME

: Test the connection
if ! @podmanBin@ version | head -10; then
  cat <<EoMessage | cut -c 3- >&2
  ⚠️ Connection test failed. Make sure Lima VM is running:
    limactl start $LIMA_VM_NAME
EoMessage
fi
