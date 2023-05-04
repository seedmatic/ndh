{...}: {
  imports = [
    ../common.nix
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./brew.nix
    #./display-manager.nix
  ];
}
