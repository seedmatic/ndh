{
  nixpkgsInput,
  config,
  pkgs,
  paths,
  ...
}:
let
  cacheTrust = import paths.catalogCacheTrust;
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
      # trusted-substituters gates which substituters non-root users may
      # add on the command line via `--substituters`. Distinct from
      # `substituters` (what's actually queried) and `trusted-public-keys`
      # (which signatures verify) — both of the latter are emitted by
      # modules/.common.d/cache-trust.nix walking the catalog.
      trusted-substituters = [
        cacheCatalog.nixos.substituter
        cacheCatalog.nxmatic.substituter
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
