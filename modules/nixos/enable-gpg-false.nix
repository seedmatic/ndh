{ lib, config, ... }:
{
  # GPG configuration for NixOS VM with agent forwarding
  # GPG is installed and usable, but the agent runs on Darwin and is forwarded via SSH

  # Note: This file is imported into hm.imports, so we're already in Home Manager context
  # No need for hm. prefix here

  # Keep GPG installed so commands work
  programs.gpg.enable = true;
  programs.gpg.homedir = "${config.xdg.dataHome}/gnupg";

  # Disable the local agent service - we use the forwarded one from Darwin
  services.gpg-agent.enable = lib.mkForce false;

  # Set environment variable to prevent shell plugins from starting a local agent
  # The forwarded socket from Darwin will be used instead
  home.sessionVariables.GPG_AGENT_FORWARDED = "1";
}
