# Podman remote configuration for macOS host (@codebase)
# This module configures the host to connect to the remote Podman engine in the Lima VM

{ config, pkgs, lib, ... }:

let
  limaVmName = "nerd-nixos";
  podmanRemoteScript = pkgs.writeShellScriptBin "podman-remote-setup" ''
    #!/usr/bin/env bash
    set -euo pipefail
    
    VM_NAME="${limaVmName}"
    SSH_INFO=$(${pkgs.lima}/bin/limactl list "$VM_NAME" --format 'table' | grep "$VM_NAME" | awk '{print $3}' | head -1)
    
    if [ -z "$SSH_INFO" ] || [ "$SSH_INFO" = "-" ]; then
      echo "❌ Lima VM '$VM_NAME' is not running or SSH not available"
      echo "💡 Start the VM with: limactl start $VM_NAME"
      exit 1
    fi
    
    # Extract IP from SSH info (format: 127.0.0.1:port)
    VM_IP=$(echo "$SSH_INFO" | cut -d':' -f1)
    
    echo "🔧 Setting up Podman remote connection to $VM_NAME ($VM_IP)"
    
    # Remove existing connection if it exists
    ${pkgs.podman}/bin/podman system connection remove lima-nixos 2>/dev/null || true
    
    # Add new remote connection via SSH using Lima's SSH config
    export CONTAINER_SSHKEY="/Users/nxmatic/.lima/_config/user"
    ${pkgs.podman}/bin/podman system connection add \
      --identity /Users/nxmatic/.lima/_config/user \
      lima-nixos \
      "ssh://nxmatic@127.0.0.1:50174/run/podman/podman.sock?secure=false"
    
    # Set as default connection
    ${pkgs.podman}/bin/podman system connection default lima-nixos
    
    echo "✅ Podman remote connection configured!"
    echo "🐳 Test with: podman --remote version"
    
    # Test the connection
    if ${pkgs.podman}/bin/podman --remote version >/dev/null 2>&1; then
      echo "🎉 Remote Podman engine is working!"
    else
      echo "⚠️  Connection test failed. Check if Podman service is running in the VM:"
      echo "   lima nerd-nixos sudo systemctl status podman.socket"
    fi
  '';

  podmanRemoteAlias = pkgs.writeShellScriptBin "podman-lima" ''
    #!/usr/bin/env bash
    # Wrapper script to use remote Podman via Lima
    exec ${pkgs.podman}/bin/podman --remote "$@"
  '';

  dockerAlias = pkgs.writeShellScriptBin "docker" ''
    #!/usr/bin/env bash
    # Docker compatibility alias for remote Podman
    exec ${pkgs.podman}/bin/podman --remote "$@"
  '';

in {
  # Add Podman and helper scripts to system packages
  environment.systemPackages = with pkgs; [
    podman
    podman-compose
    podman-tui
    skopeo
    buildah
    podmanRemoteScript
    podmanRemoteAlias
    dockerAlias
  ];

  # Create lima connection helper script
  environment.etc."podman-lima-setup.sh" = {
    text = ''
      #!/usr/bin/env bash
      # Helper script to setup Podman remote connection to Lima VM
      
      set -euo pipefail
      
      VM_NAME="${limaVmName}"
      LIMA_USER="nxmatic"
      
      echo "🚀 Setting up Podman remote connection to Lima VM..."
      
      # Check if Lima VM is running
      if ! ${pkgs.lima}/bin/limactl list | grep -q "$VM_NAME.*Running"; then
        echo "❌ Lima VM '$VM_NAME' is not running"
        echo "💡 Start it with: limactl start $VM_NAME"
        exit 1
      fi
      
      # Get VM SSH info and extract IP
      SSH_INFO=$(${pkgs.lima}/bin/limactl list "$VM_NAME" --format 'table' | grep "$VM_NAME" | awk '{print $3}' | head -1)
      
      if [ -z "$SSH_INFO" ] || [ "$SSH_INFO" = "-" ]; then
        echo "❌ Could not determine VM SSH info"
        exit 1
      fi
      
      # Extract IP from SSH info (format: 127.0.0.1:port)
      VM_IP=$(echo "$SSH_INFO" | cut -d':' -f1)
      
      echo "🔗 VM IP: $VM_IP"
      
      # Setup Podman remote connection
      ${pkgs.podman}/bin/podman system connection remove lima-nixos 2>/dev/null || true
      ${pkgs.podman}/bin/podman system connection add \
        --identity ~/.lima/_config/user \
        lima-nixos \
        ssh://lima-nerd-nixos/run/podman/podman.sock
      
      ${pkgs.podman}/bin/podman system connection default lima-nixos
      
      echo "✅ Podman remote connection configured!"
      echo "🐳 Test with: podman --remote info"
      
      # Create alias for convenience
      echo ""
      echo "💡 You can now use:"
      echo "   podman --remote <command>  # Use remote Podman"
      echo "   docker <command>           # Docker compatibility"
    '';
  };

  # Environment variables for Podman remote  
  environment.variables = {
    CONTAINER_HOST = "ssh://lima-nerd-nixos/run/podman/podman.sock";
    CONTAINER_SSHKEY = "~/.lima/_config/user";
  };
}
