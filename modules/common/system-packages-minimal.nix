{ pkgs, ... }:
# Minimal system packages for JAMF-managed macOS hosts
# Most development work happens in Lima VM, not on host
with pkgs; [
  # Essential shell and core utilities
  bash
  zsh
  coreutils-full
  
  # Nix ecosystem (required for VM management)
  flox
  direnv
  
  # Git (minimal, for flake updates)
  git
  
  # SSH (for VM access)
  # openssh is provided by macOS, but we may want specific tools
  
  # Lima VM management happens via flox environment
  # Heavy tools moved to VM
]
