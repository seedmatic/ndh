{...}:
builtins.trace "Evaluating darwin/default.nix" {
  imports = builtins.map (module: builtins.trace "Importing ${module}" (import module)) [
    ../common
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./emacs.nix
    ./raycast.nix
    ./syncthing.nix
    ./tailscale.nix
    ./homebrew.nix
  ];
}
