{
  nixpkgsInput,
  config,
  pkgs,
  ...
}:
let

  cfg = config.profile;
  user = cfg.user;
  userName = user.name;

in
{

  nix = {
    package = pkgs.nix;
    extraOptions = ''
      keep-outputs = false
      keep-derivations = false
      keep-failed = false
      experimental-features = nix-command flakes
    '';
    settings = {
      max-jobs = 4;
      trusted-users = [
        userName
        "root"
        "@admin"
        "@wheel"
      ];
      trusted-substituters = [
        "https://cache.nixos.org"
        "https://nxmatic.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nxmatic.cachix.org-1:huMghYiwDpPa1PMXHXK4G1Dp4QOZjgsNqxcjf/AjuJ0="
      ];
    };
    gc = {
      automatic = true;
      options = "--delete-older-than 1d";
    };

    registry = {
      nixpkgs = {
        from = {
          id = "nixpkgs";
          type = "indirect";
        };
        flake = nixpkgsInput;
      };
    };
  };
}
