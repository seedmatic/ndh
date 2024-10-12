{...}: {
  imports = [
    ../common.nix
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./emacs.nix
    ./raycast.nix
    ./syncthing.nix
    ./tailscale.nix
    # install un-managed programs
    ./homebrew.nix
  ];
}
