# SSH configuration for proxying connections to Linux builder VMs (@codebase)
# This module configures Darwin hosts to act as SSH proxies to their local Linux builder VMs

{ config, lib, pkgs, ... }:
let
  userName = config.profile.user.name;
  userHome = config.profile.user.home;
in
{
  # Copy builder SSH key to user's .ssh directory with proper permissions
  system.activationScripts.setupBuilderKey = lib.stringAfter ["etc"] ''
    # Create .ssh directory if it doesn't exist
    mkdir -p ${userHome}/.ssh/keys.d
    
    # Backup existing files before overwriting
    if [ -f ${userHome}/.ssh/keys.d/builder_ed25519 ]; then
      cp ${userHome}/.ssh/keys.d/builder_ed25519 ${userHome}/.ssh/keys.d/builder_ed25519.before-nix-darwin
    fi
    if [ -f ${userHome}/.ssh/keys.d/builder_ed25519.pub ]; then
      cp ${userHome}/.ssh/keys.d/builder_ed25519.pub ${userHome}/.ssh/keys.d/builder_ed25519.pub.before-nix-darwin
    fi
    
    # Copy the builder private key with proper permissions
    cp /etc/nix/builder_ed25519 ${userHome}/.ssh/keys.d/builder_ed25519
    chmod 600 ${userHome}/.ssh/keys.d/builder_ed25519
    chown ${userName}:staff ${userHome}/.ssh/keys.d/builder_ed25519
    
    # Copy the public key too
    cp /etc/nix/builder_ed25519.pub ${userHome}/.ssh/keys.d/builder_ed25519.pub
    chmod 644 ${userHome}/.ssh/keys.d/builder_ed25519.pub
    chown ${userName}:staff ${userHome}/.ssh/keys.d/builder_ed25519.pub
    
        # Ensure the directory has correct ownership
    chown ${userName}:staff ${userHome}/.ssh/keys.d
  '';

  # SSH configuration for connecting to the Linux builder

  # Configure SSH to proxy connections to the local Linux builder
  programs.ssh.extraConfig = ''
    # Local Linux builder VM configuration
    Host linux-builder
      HostName linux-builder
      User builder
      Port 22
      IdentityFile ${userHome}/.ssh/keys.d/builder_ed25519
      IdentitiesOnly yes
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel QUIET
      # Enable connection multiplexing for better performance
      ControlMaster auto
      ControlPath /tmp/ssh-builder-%r@%h:%p
      ControlPersist 10m
      # Optimize for bulk transfers (build artifacts)
      Compression yes
      TCPKeepAlive yes
      # Increase batch size for file transfers
      BatchMode yes
  '';

  # Ensure the user can access the Linux builder
  # The linux-builder VM should be accessible via the nix.linux-builder configuration
  assertions = [
    {
      assertion = config.nix.linux-builder.enable;
      message = "Linux builder must be enabled for SSH proxy configuration";
    }
  ];
}
