{pkgs, ...}:
builtins.traceVerbose "Evaluating darwin/environment.nix" {
  imports = builtins.map (module: builtins.traceVerbose "Importing ${module}" (import module)) [
    ./emacs.nix
    ./raycast.nix
    ./socket_vmnet.nix
    ./syncthing.nix
    ./tailscale.nix
    ./homebrew.nix
  ];

  environment.systemPackages = with pkgs; [
    bfg-repo-cleaner
    nmap
  ];
}
