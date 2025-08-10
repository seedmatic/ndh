# SSH configuration for proxying connections to Linux builder VMs (@codebase)
# This module configures Darwin hosts to act as SSH proxies to their local Linux builder VMs

{ config, lib, pkgs, ... }:
let
  userName = config.profile.user.name;
  userHome = config.profile.user.home;
in
{
  # SSH keys are automatically managed by distributed-builds.nix via environment.etc
  # No activation script needed - the keys are deployed to /etc/nix/ automatically

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
      # Connection timeouts
      ConnectTimeout 10
      ServerAliveInterval 30
      ServerAliveCountMax 3
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
