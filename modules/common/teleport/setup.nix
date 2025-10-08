{ config, lib, pkgs, ... }:

# Helper scripts for Teleport setup and management

let
  setupScript = pkgs.writeShellScriptBin "teleport-setup" ''
    set -euxo pipefail
    
    : "=== Teleport Initial Setup ==="
    
    : "Check if Teleport is running"
    if ! pgrep -x teleport > /dev/null; then
      echo "Error: Teleport is not running." >&2
      echo "Start it with: sudo launchctl load /Library/LaunchDaemons/com.gravitational.teleport.plist" >&2
      exit 1
    fi
    
    : "1. Creating initial admin user"
    ${pkgs.teleport}/bin/tctl users add admin --roles=editor,access --logins=nxmatic,root
    
    : "2. Generating node join token"
    TOKEN=$(${pkgs.teleport}/bin/tctl tokens add --type=node --ttl=24h --format=text)
    echo "Node join token: $TOKEN"
    echo ""
    echo "Use this token in your NixOS configuration:"
    echo "  services.teleport-node.authToken = \"$TOKEN\";"
    
    : "3. Importing RBAC roles"
    ${pkgs.teleport}/bin/teleport-import-roles
    
    : "=== Setup Complete ==="
    echo "Access the web UI at: https://$(hostname).mammoth-skate.ts.net:3080"
  '';
  
  statusScript = pkgs.writeShellScriptBin "teleport-status" ''
    set -euxo pipefail
    
    : "=== Teleport Cluster Status ==="
    
    if ! command -v tctl &> /dev/null; then
      echo "Error: tctl not found" >&2
      exit 1
    fi
    
    : "Cluster info"
    ${pkgs.teleport}/bin/tctl status
    
    : "Connected nodes"
    ${pkgs.teleport}/bin/tctl nodes ls
    
    : "Active users"
    ${pkgs.teleport}/bin/tctl users ls
    
    : "Roles"
    ${pkgs.teleport}/bin/tctl get roles --format=names
  '';
  
  connectScript = pkgs.writeShellScriptBin "teleport-connect" ''
    set -euxo pipefail
    
    PROXY="''${TELEPORT_PROXY:-$(hostname).mammoth-skate.ts.net:3080}"
    
    if [ $# -eq 0 ]; then
      echo "Usage: teleport-connect <node-name>" >&2
      echo "" >&2
      echo "Available nodes:" >&2
      ${pkgs.teleport}/bin/tsh --proxy=$PROXY ls
      exit 1
    fi
    
    NODE="$1"
    shift
    
    : "Connecting to $NODE via Teleport"
    ${pkgs.teleport}/bin/tsh --proxy=$PROXY ssh "$NODE" "$@"
  '';
in
{
  environment.systemPackages = [
    setupScript
    statusScript
    connectScript
  ];
}
