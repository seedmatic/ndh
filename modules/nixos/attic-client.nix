# A machine's side of the private caches (docs/private-binary-cache-spec.adoc, per-metalspace): it
# reads every metalspace's cache, and its watch-store pushes what it builds into its own
# metalspace's. Both are OFF until the tokens can be delivered: they are read from FIXED paths that
# the token delivery (roles × keys' S3b drop-box) fills, and nothing here mints or stores one.
#
# The caches are named by the catalog (`atticFqdn`), and served under the fleet's TLS root, which
# security.pki already trusts. A cache's public key enters `trusted-public-keys` only once accepted for
# this machine's kind (catalog/private-caches.nix): the keys are read from the catalog, never given here.
{
  config,
  lib,
  ndh,
  ...
}:
let
  cfg = config.ndh.atticClient;
  netplan = ndh.context.catalog.netplan;
  publicKeys = ndh.context.catalog.privateCaches.readKeysFor "nixos";
  url = fqdn: "https://${fqdn}/${cfg.cacheName}";
  # Its own metalspace's cache first: the other one is reached through the tunnel. Both after the
  # upstream and public tiers (cache.nixos.org's priority is 40).
  priority = fqdn: if fqdn == cfg.ownCache then 50 else 51;
in
{
  options.ndh.atticClient = {
    paths = lib.mkOption {
      readOnly = true;
      default = {
        dir = "/run/ndh-attic";
        # nix's netrc: one `machine <fqdn> password <read token>` per cache.
        netrc = "/run/ndh-attic/netrc";
        # The write token to this machine's own metalspace's cache.
        writeToken = "/run/ndh-attic/write.token";
      };
      description = "Where the token delivery puts this machine's attic tokens (tmpfs, root-only).";
    };

    caches = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.mapAttrsToList (_: bm: bm.atticFqdn) (netplan.baremetal or { });
      defaultText = lib.literalExpression "every metalspace's atticFqdn";
      description = "The caches this machine reads, by fabric name.";
    };

    ownCache = lib.mkOption {
      type = lib.types.str;
      example = "attic.bioskop";
      description = "This machine's own metalspace's cache: read first, and the one its watch-store pushes to.";
    };

    cacheName = lib.mkOption {
      type = lib.types.str;
      default = "seedmatic";
      description = "The cache every attic serves (ndh.atticCache.cacheName).";
    };

    read.enable = lib.mkEnableOption "substituting from the private caches, with the delivered read tokens";

    watchStore.enable = lib.mkEnableOption "pushing what this machine builds into its own metalspace's cache";
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.read.enable {
      assertions = [
        {
          assertion = publicKeys != [ ];
          message = "ndh.atticClient.read: no accepted cache key — a substituter whose signatures nothing checks";
        }
      ];
      nix.settings = {
        extra-substituters = map (fqdn: "${url fqdn}?priority=${toString (priority fqdn)}") cfg.caches;
        extra-trusted-public-keys = publicKeys;
        # Absent until the delivery: nix then simply holds no credential for the caches.
        netrc-file = cfg.paths.netrc;
      };
    })

    (lib.mkIf cfg.watchStore.enable {
      # Started as soon as the delivery writes the token, and at every boot once it is there.
      systemd.paths.ndh-attic-watch-store = {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathExists = cfg.paths.writeToken;
      };
      systemd.services.ndh-attic-watch-store = {
        description = "Push this machine's new store paths into ${cfg.ownCache}";
        after = [
          "network-online.target"
          "nix-daemon.service"
        ];
        wants = [ "network-online.target" ];
        unitConfig.ConditionPathExists = cfg.paths.writeToken;
        environment.SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        serviceConfig = {
          DynamicUser = true;
          RuntimeDirectory = "ndh-attic-watch-store";
          RuntimeDirectoryMode = "0700";
          # The token reaches the service only, never its environment nor an argument.
          LoadCredential = "write.token:${cfg.paths.writeToken}";
          Restart = "on-failure";
          RestartSec = 30;
        };
        script = ''
          export HOME="$RUNTIME_DIRECTORY" XDG_CONFIG_HOME="$RUNTIME_DIRECTORY"
          mkdir -p "$XDG_CONFIG_HOME/attic"
          cat >"$XDG_CONFIG_HOME/attic/config.toml" <<EOF
          default-server = "own"

          [servers.own]
          endpoint = "https://${cfg.ownCache}/"
          token-file = "$CREDENTIALS_DIRECTORY/write.token"
          EOF
          exec ${lib.getExe' config.ndh.atticPkgs.client "attic"} watch-store ${lib.escapeShellArg "own:${cfg.cacheName}"}
        '';
      };
    })
  ];
}
