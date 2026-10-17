# A darwin host's side of the private caches (modules/.common.d/attic-client.nix): where the token
# delivery (roles x keys' S3b, its darwin twin reading this seat's own drop-box) puts its tokens, and its
# watch-store as a launchd daemon. macOS has no /run tmpfs; /var/run is emptied at every boot.
{
  config,
  lib,
  ndh,
  ...
}:
let
  cfg = config.ndh.atticClient;
  log = "/var/log/ndh-attic-watch-store.log";
in
{
  config = lib.mkMerge [
    {
      ndh.atticClient = {
        kind = "darwin";
        paths = {
          dir = "/var/run/ndh-attic";
          # nix's netrc: one `machine <fqdn> password <read token>` per cache.
          netrc = "/var/run/ndh-attic/netrc";
          # The write token to this machine's own metalspace's cache.
          writeToken = "/var/run/ndh-attic/write.token";
        };
      };
    }

    (lib.mkIf cfg.watchStore.enable {
      launchd.daemons.ndh-attic-watch-store = {
        # attic reads its token from a file named in its config, so neither reaches an argument nor the
        # environment; the config lives in a root-only directory under /var/run, gone at boot like the token.
        script = ''
          set -euo pipefail
          umask 077
          export HOME=/var/run/ndh-attic-watch-store XDG_CONFIG_HOME=/var/run/ndh-attic-watch-store
          export SSL_CERT_FILE=/etc/ssl/cert.pem
          mkdir -p "$XDG_CONFIG_HOME/attic"
          cat >"$XDG_CONFIG_HOME/attic/config.toml" <<EOF
          default-server = "own"

          [servers.own]
          endpoint = "https://${cfg.ownCache}/"
          token-file = "${cfg.paths.writeToken}"
          EOF
          exec ${lib.getExe' config.ndh.atticPkgs.client "attic"} watch-store ${lib.escapeShellArg "own:${cfg.cacheName}"}
        '';
        serviceConfig = {
          Label = ndh.store.mkLaunchdLabel "attic-watch-store";
          # Running exactly while the delivery's token is there: started when it lands, stopped if it goes.
          KeepAlive.PathState.${cfg.paths.writeToken} = true;
          ThrottleInterval = 30;
          StandardOutPath = log;
          StandardErrorPath = log;
        };
      };
    })
  ];
}
