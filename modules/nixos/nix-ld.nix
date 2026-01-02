{
  config,
  pkgs,
  lib,
  ...
}:

{
  # Enable nix-ld to run dynamically linked binaries (e.g., Lima guest agent)
  # This provides a compatibility layer for running non-NixOS binaries
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      # Common libraries needed by dynamically linked binaries
      stdenv.cc.cc.lib
      zlib
      glibc
    ];
  };
}
