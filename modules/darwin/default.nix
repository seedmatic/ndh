{...}: {
  imports = [
    ../common.nix
    ./preferences.nix
    ./security.nix
    ./brew.nix
    ./core.nix
    ./lorri.nix
    ./emacs.nix
    #./display-manager.nix
  ];
}
