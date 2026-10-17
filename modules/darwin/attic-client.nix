# A darwin host's side of the private caches (modules/.common.d/attic-client.nix): where the token
# delivery (roles x keys' S3b, its darwin twin reading this seat's own drop-box) puts its tokens, and its
# watch-store as a launchd daemon under its own account, never root: launchd has no LoadCredential, so the
# delivery hands write.token to that account (writeTokenOwner). macOS has no /run tmpfs; /var/run is emptied at
# every boot, so the account's home, which holds only attic's config (the token's path, never the token), is
# under /var/db.
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  cfg = config.ndh.atticClient;
  account = "_ndh-attic";
  home = "/var/db/ndh-attic-watch-store";
  log = "${home}/watch-store.log";
  # Its identity is its own host key, the access point the tokens are sealed to, converted in memory.
  unseal = import ../.common.d/attic-tokens.d/package.nix {
    inherit pkgs lib;
    inherit (ndh.context.catalog) netplan;
    inherit (cfg) paths;
    identityMode = "hostkey";
    identity = config.ndh.hostKey.file;
  };
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
        writeTokenOwner = account;
      };
    }

    (lib.mkIf (cfg.read.enable || cfg.watchStore.enable) {
      # The tokens rest as ciphertext; /var/run is emptied at every boot, so they are unsealed at load.
      launchd.daemons.ndh-attic-tokens.serviceConfig = {
        Label = ndh.store.mkLaunchdLabel "attic-tokens";
        ProgramArguments = [ (lib.getExe unseal) ];
        RunAtLoad = true;
        StandardErrorPath = "/var/log/ndh-attic-tokens.log";
      };
    })

    (lib.mkIf cfg.watchStore.enable {
      users = {
        knownUsers = [ account ];
        knownGroups = [ account ];
        groups.${account}.gid = 30002;
        users.${account} = {
          uid = 631;
          gid = config.users.groups.${account}.gid;
          description = "attic watch-store";
          inherit home;
          shell = "/usr/bin/false";
          isHidden = true;
        };
      };

      system.activationScripts.postActivation.text = lib.mkAfter ''
        install -d -o ${account} -g ${account} -m 0700 ${home}
      '';

      launchd.daemons.ndh-attic-watch-store = {
        # attic reads its token from a file named in its config, so neither reaches an argument nor the
        # environment.
        script = ''
          set -euo pipefail
          umask 077
          export HOME=${home} XDG_CONFIG_HOME=${home}
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
          UserName = account;
          GroupName = account;
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
