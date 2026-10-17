# The public level's publication on a darwin host (docs/private-binary-cache-spec.adoc,
# public-private-split): cache-publish, run as a dedicated `_ndh-publish` user that holds this access
# point's cachix push token and nothing else, never a trusted user of the daemon. Off by default; it
# is a gesture (`sudo -u _ndh-publish -H cache-publish [--apply] <revision>`), never a service.
#
# No publication key (the operator, 2026-10-17): adding a signature to the store needs a trusted user,
# and the public trust is nxmatic.cachix.org-1, which cachix applies to what it serves.
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  cfg = config.ndh.cachePublish;
  catalog = ndh.context.catalog;
  tokenSecret = "cache-publish.token";
  publicUrl = catalog.caches.nxmatic.substituter;
  # The allow-list: every machine's system, from catalog/machines.nix. The tool keeps their aggregates
  # private by itself; what publishes is their clean packages.
  toplevel =
    machine:
    if machine.kind == "darwin" then
      "darwinConfigurations.${machine.name}.system"
    else
      "nixosConfigurations.${machine.name}.config.system.build.toplevel";
  # Already public: the caches every host substitutes from, but the one we publish to, so that a
  # private path found there is reported as a leak rather than taken for upstream.
  upstreams = lib.filter (url: url != publicUrl) (
    lib.mapAttrsToList (_: entry: entry.substituter) (
      lib.filterAttrs (_: entry: entry ? substituter) catalog.caches
    )
  );
  package = import ../.common.d/cache-publish.d/package.nix {
    inherit
      pkgs
      lib
      upstreams
      publicUrl
      ;
    outputs = map toplevel catalog.machines;
    cache = "nxmatic";
    tokenFile = config.sops.secrets.${tokenSecret}.path;
    # The canonical remote, as ndh-switch reads it: a fork serves its commits under the same github: name.
    remote = "https://github.com/seedmatic/ndh";
  };
in
{
  options.ndh.cachePublish = {
    enable = lib.mkEnableOption "publishing this access point's builds to the public cache, as a gesture";

    sopsFile = lib.mkOption {
      type = lib.types.path;
      description = "The sops file holding this access point's cachix push token, at cachix/nxmatic/publish/<host>.";
    };

    user = lib.mkOption {
      readOnly = true;
      default = {
        name = "_ndh-publish";
        uid = 631;
        gid = 631;
        home = "/var/lib/ndh-publish";
      };
      description = "The publishing user: its own uid and group, no login, no membership elsewhere.";
    };
  };

  config = lib.mkIf cfg.enable {
    users = {
      knownGroups = [ cfg.user.name ];
      groups.${cfg.user.name}.gid = cfg.user.gid;
      knownUsers = [ cfg.user.name ];
      users.${cfg.user.name} = {
        inherit (cfg.user) uid gid home;
        createHome = true;
        shell = "/usr/bin/false";
        description = "Publishes this access point's builds to the public cache";
      };
    };

    # Decrypted for the publishing user alone.
    sops.secrets.${tokenSecret} = {
      format = "yaml";
      inherit (cfg) sopsFile;
      key = "cachix/nxmatic/publish/${config.networking.hostName}";
      owner = cfg.user.name;
      mode = "0400";
    };

    environment.systemPackages = [ package ];
  };
}
