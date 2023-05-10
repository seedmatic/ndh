{...}: {
  imports = [
    ../common.nix
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./brew.nix
    ./lorri.nix
    #./display-manager.nix
  ];
}
