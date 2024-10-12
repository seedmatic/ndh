{...}: {
  imports = [
    ../common.nix
    ./preferences.nix
    ./security.nix
    ./core.nix
    #./display-manager.nix
    ./emacs.nix
    #./keybase.nix
    #./lorri.nix
    ./raycast.nix
    ./syncthing.nix
    ./tailscale.nix
    # install un-managed programs
    ./homebrew.nix
  ];
}
