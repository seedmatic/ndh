# SSH configuration for proxying connections to Linux builder VMs (@codebase)
# This module configures Darwin hosts to act as SSH proxies to their local Linux builder VMs

{ config, lib, pkgs, ... }:

{
  # Configure SSH to proxy connections to the local Linux builder
  programs.ssh.extraConfig = ''
    # Local Linux builder VM configuration
    Host linux-builder
      HostName linux-builder
      User builder
      Port 22
      IdentityFile /etc/nix/builder_ed25519
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel QUIET
      # Enable connection multiplexing for better performance
      ControlMaster auto
      ControlPath /tmp/ssh-%r@%h:%p
      ControlPersist 60s
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
