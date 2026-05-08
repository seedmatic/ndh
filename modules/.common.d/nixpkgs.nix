{
  nixpkgsInput,
  config,
  pkgs,
  self,
  ...
}:
let
  cacheTrust = import "${self}/catalog/cache-trust.nix";
  cacheCatalog = cacheTrust.caches;

  cfg = config.profile;
  user = cfg.user;
  userName = user.name;

in
{

  nix = {
    package = pkgs.nix;
    # experimental-features declared in modules/.common.d/nix-settings.nix;
    # keep the raw GC toggles here.
    extraOptions = ''
      keep-outputs = false
      keep-derivations = false
      keep-failed = false
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
        cacheCatalog.nixos.substituter
        cacheCatalog.nxmatic.substituter
      ];
      trusted-public-keys = [
        cacheCatalog.nixos.publicKey
        cacheCatalog.nxmatic.publicKey
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
