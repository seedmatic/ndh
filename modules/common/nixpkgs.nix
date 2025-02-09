{
  inputs,
  config,
  pkgs,
  ...
}: let

  cfg = config.profile;
  user = cfg.user;
  userName = user.name;

in {
  nixpkgs = {
    config = import ./config.nix;
  };

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
      trusted-users = [ userName "root" "@admin" "@wheel" ];
      trusted-substituters = [
        "https://cache.nixos.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ];
    };
    gc = {
      automatic = true;
      options = "--delete-older-than 1d";
    };

    nixPath =
      builtins.map
      (source: "${source}=/etc/${config.environment.etc.${source}.target}") [
        "home-manager"
        "nixpkgs"
      ];
    registry = {
      nixpkgs = {
        from = {
          id = "nixpkgs";
          type = "indirect";
        };
        flake = inputs.nixpkgs;
      };
    };
  };
}
