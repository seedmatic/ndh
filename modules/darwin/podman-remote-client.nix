# Podman remote configuration for macOS host (@codebase)
# This module configures the host to connect to the remote Podman engine in the Lima VM using containers.conf

{
  config,
  pkgs,
  lib,
  ...
}:

let
  dollar = "$";
  profileUser = config.profile.user.name; # Use profile-configured username

  # Generate containers.conf that dynamically resolves Lima VM connection details
  containers-conf = pkgs.writeShellScript "generate-containers-conf" ''
        #!/usr/bin/env bash
        set -euo pipefail

        LIMA_VM_NAME="${dollar}{LIMA_VM_NAME:-nerd-nixos}"
        LIMA_USER="${dollar}{LIMA_USER:-${profileUser}}"
        LIMA_IDENTITY_FILE="$HOME/.lima/_config/user"
        
        : Check if Lima VM is running
        if ! ${pkgs.lima}/bin/limactl list "$LIMA_VM_NAME" --format=yaml | ${pkgs.yq-go}/bin/yq -e '.instance.status == "Running"' >/dev/null 2>&1; then
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
        SSH_HOST=$(${pkgs.lima}/bin/limactl list "$LIMA_VM_NAME" --format=yaml | ${pkgs.yq-go}/bin/yq '.instance.sshAddress')
        SSH_PORT=$(${pkgs.lima}/bin/limactl list "$LIMA_VM_NAME" --format=yaml | ${pkgs.yq-go}/bin/yq '.instance.sshLocalPort')
        
        cat <<EOF
    [engine]
    remote = true

    [engine.service_destinations]
    [engine.service_destinations.lima-$LIMA_VM_NAME]
    uri = "ssh://$LIMA_USER@$SSH_HOST:$SSH_PORT/run/podman/podman.sock"
    identity = "$LIMA_IDENTITY_FILE"
    default = true
    EOF
  '';

  podman-remote-setup = pkgs.writeShellScriptBin "podman-remote-setup" ''
    #!/usr/bin/env bash
    set -euo pipefail

    LIMA_VM_NAME="${dollar}{LIMA_VM_NAME:-nerd-nixos}"
    LIMA_CONTEXT_NAME="lima-${dollar}{LIMA_VM_NAME}"
    LIMA_USER="${dollar}{LIMA_USER:-${profileUser}}"
    LIMA_IDENTITY_FILE="$HOME/.lima/_config/user"
    LIMA_SSH_HOST="$LIMA_CONTEXT_NAME"

    : Create containers config directory
    mkdir -p "$HOME/.config/containers"

    : Generate and install containers.conf
    ${containers-conf} > "$HOME/.config/containers/containers.conf"

    : Create Docker context for Lima VM
    ${pkgs.docker}/bin/docker context rm -f $LIMA_CONTEXT_NAME 2>/dev/null
    ${pkgs.docker}/bin/docker context create $LIMA_CONTEXT_NAME \
      --description "Lima $LIMA_VM_NAME Podman via SSH" \
      --docker "host=ssh://$LIMA_SSH_HOST"
    ${pkgs.docker}/bin/docker context use $LIMA_CONTEXT_NAME

    : Test the connection
    if ! ${pkgs.podman}/bin/podman version | head -10; then
      cat <<EoMessage | cut -c 3- >&2
      ⚠️ Connection test failed. Make sure Lima VM is running:
        limactl start $LIMA_VM_NAME
    EoMessage
    fi
  '';

in
{
  # Add Podman and helper scripts to system packages
  # Note: No global environment variables set
  #       SSH configuration and Podman connections are managed through containers.conf
  environment.systemPackages = with pkgs; [
    buildah
    docker
    podman
    podman-compose
    podman-remote-setup
    podman-tui
    skopeo
  ];

}
