# A darwin host's side of the private caches (modules/.common.d/attic-client.nix): where the token
# delivery (modules/.common.d/attic-tokens.d) unseals its tokens, and its watch-store as a launchd daemon
# under its own account, never root: launchd has no LoadCredential, so the unseal hands write.token to that
# account (writeTokenOwner). macOS has no /run tmpfs; /var/run is emptied at
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
  tokens = import ../.common.d/attic-tokens.d/package.nix {
    inherit pkgs lib;
    inherit (ndh.context.catalog) netplan;
  };
  # Its identity is its own host key, the access point the tokens are sealed to, converted in memory.
  unseal = tokens.unseal {
    inherit (cfg) paths writeTokenOwner;
    identityMode = "hostkey";
    identity = config.ndh.hostKey.file;
  };
  receive = tokens.receive {
    machine = config.networking.hostName;
    unsealer = unseal;
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

    {
      # The tokens rest as ciphertext; /var/run is emptied at every boot, so they are unsealed at load. Present
      # before the client is enabled, so a deposit lands first and the client starts on tokens in place.
      # The account exists with them: the unseal gives it write.token.
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

      # The operator seat's deposit reaches it by its fixed path under sudo -n: that one command, nothing else.
      environment.systemPackages = [ receive ];
      security.sudo.extraConfig = ''
        ${config.profile.user.name} ALL=(root) NOPASSWD: /run/current-system/sw/bin/ndh-attic-tokens-receive
      '';
      launchd.daemons.ndh-attic-tokens = {
        command = lib.getExe unseal;
        serviceConfig = {
          Label = ndh.store.mkLaunchdLabel "attic-tokens";
          RunAtLoad = true;
          StandardErrorPath = "/var/log/ndh-attic-tokens.log";
        };
      };
    }

    # The keyring seat deposits every other live machine's tokens, by the operator's ssh name for each.
    (lib.mkIf config.ndh.keyring.enable {
      environment.systemPackages = [
        (tokens.deposit {
          seat = config.networking.hostName;
          localReceive = receive;
          targets = map (m: {
            inherit (m) name kind;
            ssh = "${m.kind}.${m.metalspace}";
          }) (lib.filter (m: m.name != config.networking.hostName) ndh.context.catalog.machines);
        })
      ];
    })

    (lib.mkIf cfg.watchStore.enable {
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
