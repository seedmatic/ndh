{
  nixpkgsInput,
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  cacheCatalog = ndh.context.catalog.caches;

  cfg = config.profile;
  user = cfg.user;
  userName = user.name;

in
{
  assertions = [
    {
      assertion = !lib.any (lib.hasPrefix "@") config.nix.settings.trusted-users;
      message = "nix trusted-users holds a group (${lib.concatStringsSep ", " (lib.filter (lib.hasPrefix "@") config.nix.settings.trusted-users)}): name the accounts";
    }
  ];

  nix = {
    package = pkgs.nix;
    # experimental-features declared in modules/.common.d/nix-settings.nix.
    settings = {
      # The GC toggles, as defaults: a raw extraOptions line comes after every setting in nix.conf
      # and wins over them, so a module needing another value could not set it — the store freeze
      # needs keep-derivations.
      keep-outputs = lib.mkDefault false;
      keep-derivations = lib.mkDefault false;
      keep-failed = lib.mkDefault false;
      # Named accounts only: a trusted user is root to the daemon, and a group entry would extend that to
      # whoever joins the group later, with no change here. The assertion below holds it on every machine.
      trusted-users = [
        userName
        "root"
      ];
      # trusted-substituters gates which substituters non-root users may
      # add on the command line via `--substituters`. Distinct from
      # `substituters` (what's actually queried) and `trusted-public-keys`
      # (which signatures verify) — both of the latter are emitted by
      # modules/.common.d/cache-trust.nix walking the catalog.
      trusted-substituters = [
        cacheCatalog.nixos.substituter
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
