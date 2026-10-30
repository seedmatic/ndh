# A machine's side of the private caches (docs/private-binary-cache-spec.adoc, per-metalspace): it
# reads every metalspace's cache, and its watch-store pushes what it builds into its own
# metalspace's. Both are OFF until the tokens can be delivered: they are read from FIXED paths that
# the token delivery (modules/.common.d/attic-tokens.d) fills, and nothing here mints one.
#
# The caches are named by the catalog (`atticFqdn`), and served in plain HTTP on the fabric (no TLS in the lab: what
# a cache serves is signed by its key, and its tokens travel as age ciphertext). A cache's public key enters `trusted-public-keys` only once accepted for
# this machine's kind (catalog/private-caches.nix): the keys are read from the catalog, never given here.
#
# Platform-agnostic: the paths and the watch-store's service live in modules/{darwin,nixos}/attic-client.nix.
{
  config,
  lib,
  ndh,
  ...
}:
let
  cfg = config.ndh.atticClient;
  netplan = ndh.context.catalog.netplan;
  publicKeys = ndh.context.catalog.privateCaches.readKeysFor cfg.kind;
  url = fqdn: "http://${fqdn}/${cfg.cacheName}";
  # Its own metalspace's cache first: the other one is reached through the tunnel. Both after the
  # upstream and public tiers (cache.nixos.org's priority is 40).
  priority = fqdn: if fqdn == cfg.ownCache then 50 else 51;
  machine = lib.findFirst (m: m.name == config.networking.hostName) { } ndh.context.catalog.machines;
in
{
  options.ndh.atticClient = {
    kind = lib.mkOption {
      type = lib.types.enum [
        "darwin"
        "nixos"
      ];
      internal = true;
      description = "This machine's kind in catalog/machines.nix, set by the platform module: it selects the accepted keys.";
    };

    paths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = "Where the token delivery puts this machine's attic tokens (gone at boot): dir, netrc, writeToken.";
    };

    writeTokenOwner = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "The account the token delivery gives writeToken to, 0400; netrc stays root's, 0400, and dir must let that account through.";
    };

    caches = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.mapAttrsToList (_: bm: bm.atticFqdn) (netplan.baremetal or { });
      defaultText = lib.literalExpression "every metalspace's atticFqdn";
      description = "The caches this machine reads, by fabric name.";
    };

    metalspace = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      # Null outside the fleet's inventory (a generic bringup image): its unit is then not built (attic-client.nix).
      default =
        let
          m = lib.findFirst (m: m.name == config.networking.hostName) null ndh.context.catalog.machines;
        in
        if m == null then null else m.metalspace;
      defaultText = lib.literalExpression "this machine's metalspace in catalog/machines.nix, or null";
      description = "This machine's metalspace: the one cache that also gives it a write token.";
    };

    ownCache = lib.mkOption {
      type = lib.types.str;
      default = netplan.baremetal.${cfg.metalspace}.atticFqdn;
      defaultText = lib.literalExpression "netplan.baremetal.\${metalspace}.atticFqdn";
      example = "attic.bioskop";
      description = "This machine's own metalspace's cache: read first, and the one its watch-store pushes to.";
    };

    cacheName = lib.mkOption {
      type = lib.types.str;
      default = "seedmatic";
      description = "The cache every attic serves (ndh.atticCache.cacheName).";
    };

    read.enable =
      lib.mkEnableOption "substituting from the private caches, with the delivered read tokens"
      // {
        default = machine.attic.read or false;
        defaultText = lib.literalExpression "this machine's attic.read in catalog/machines.nix, or false";
      };

    watchStore.enable =
      lib.mkEnableOption "pushing what this machine builds into its own metalspace's cache"
      // {
        default = machine.attic.push or false;
        defaultText = lib.literalExpression "this machine's attic.push in catalog/machines.nix, or false";
      };
  };

  config = lib.mkIf cfg.read.enable {
    assertions = [
      {
        assertion = publicKeys != [ ];
        message = "ndh.atticClient.read: no cache key accepted for ${cfg.kind} — a substituter whose signatures nothing checks";
      }
    ];
    nix.settings = {
      extra-substituters = map (fqdn: "${url fqdn}?priority=${toString (priority fqdn)}") cfg.caches;
      extra-trusted-public-keys = publicKeys;
      # Absent until the delivery: nix then simply holds no credential for the caches.
      netrc-file = cfg.paths.netrc;
      # A cache that does not answer (the other metalspace's, through the tunnel) must not hold a build: nix gives up
      # on it after this and goes on with the next substituter.
      connect-timeout = lib.mkDefault 5;
    };
  };
}
