{ pkgs, ... }:
# Minimal system packages for JAMF-managed macOS hosts
# Most development work happens in the VM, not on host
with pkgs;
[
  # Essential shell and core utilities
  bash
  zsh
  coreutils-full

  # Nix ecosystem (required for VM management)
  # flox removed - must be installed via flox itself before bootstrap
  direnv
  nix-darwin # For darwin-rebuild command

  # Git (minimal, for flake updates)
  git

  # SSH (for VM access)
  # openssh is provided by macOS, but we may want specific tools

  # Heavy tools moved to VM
]
