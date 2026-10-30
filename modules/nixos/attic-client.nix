# A NixOS guest's side of the private caches (modules/.common.d/attic-client.nix): where the token
# delivery puts its tokens, and its watch-store as a systemd service.
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  cfg = config.ndh.atticClient;
  tokens = import ../.common.d/attic-tokens.d/package.nix {
    inherit pkgs lib;
    inherit (ndh.context.catalog) netplan;
  };
  # Its identity is its own host key, the one its tokens are sealed to, converted in memory: a guest decrypts with its
  # served key and holds no age file.
  unseal = tokens.unseal {
    inherit (cfg) paths writeTokenOwner;
    identity = config.ndh.hostKey.file;
  };
in
{
  config = lib.mkMerge [
    {
      ndh.atticClient = {
        kind = "nixos";
        paths = {
          dir = "/run/ndh-attic";
          # nix's netrc: one `machine <fqdn> password <read token>` per cache.
          netrc = "/run/ndh-attic/netrc";
          # The write token to this machine's own metalspace's cache.
          writeToken = "/run/ndh-attic/write.token";
        };
        # LoadCredential reads it as root and hands the service its own copy.
        writeTokenOwner = "root";
      };
    }

    # A machine outside the fleet's inventory (a generic bringup image) has no token to pull.
    (lib.mkIf (cfg.metalspace != null) {
      # The tokens rest as ciphertext; their tmpfs paths are filled at boot and at every pull, once the identity is
      # placed. Each machine pulls its own from every cache (F6): daily, and at boot after the identity; the unseal
      # runs at the end of each pull.
      systemd.tmpfiles.rules = [ "d ${tokens.store} 0700 root root - -" ];
      systemd.services.ndh-attic-tokens = {
        description = "Pull and unseal this machine's attic tokens into ${cfg.paths.dir}";
        wantedBy = [ "multi-user.target" ];
        # The attic names are this guest's own dnsmasq's: at boot the pull ran before it and could not resolve them. A
        # cache that does not answer yet (its container still starting) fails the pull, which retries every 30 s for an
        # hour; past that, the daily timer takes over.
        after = [
          "sops-install-secrets.service"
          "network-online.target"
          "nss-lookup.target"
          "dnsmasq.service"
        ];
        wants = [
          "network-online.target"
          "nss-lookup.target"
        ];
        unitConfig = {
          StartLimitIntervalSec = 3600;
          StartLimitBurst = 120;
        };
        serviceConfig = {
          Type = "oneshot";
          Restart = "on-failure";
          RestartSec = 30;
          ExecStart = lib.getExe (
            tokens.fetch {
              machine = config.networking.hostName;
              inherit (cfg) metalspace;
              inherit (config.ndh.keysYaml) keys;
              unsealer = unseal;
            }
          );
        };
      };
      systemd.timers.ndh-attic-tokens = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
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
          endpoint = "http://${cfg.ownCache}/"
          token-file = "$CREDENTIALS_DIRECTORY/write.token"
          EOF
          exec ${lib.getExe' config.ndh.atticPkgs.client "attic"} watch-store ${lib.escapeShellArg "own:${cfg.cacheName}"}
        '';
      };
    })
  ];
}
