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
  # Its identity is the sops keyFile: its access point's age identity, the one the tokens are sealed to.
  unseal = import ../.common.d/attic-tokens.d/package.nix {
    inherit pkgs lib;
    inherit (ndh.context.catalog) netplan;
    inherit (cfg) paths;
    identityMode = "keyfile";
    identity = config.sops.age.keyFile;
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

    (lib.mkIf (cfg.read.enable || cfg.watchStore.enable) {
      # The tokens rest as ciphertext; their tmpfs paths are filled at every boot, once the identity is placed.
      systemd.tmpfiles.rules = [ "d ${unseal.store} 0700 root root - -" ];
      systemd.services.ndh-attic-tokens = {
        description = "Unseal this machine's attic tokens into ${cfg.paths.dir}";
        wantedBy = [ "multi-user.target" ];
        after = [ "sops-install-secrets.service" ];
        unitConfig.ConditionDirectoryNotEmpty = unseal.store;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe unseal;
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
          endpoint = "https://${cfg.ownCache}/"
          token-file = "$CREDENTIALS_DIRECTORY/write.token"
          EOF
          exec ${lib.getExe' config.ndh.atticPkgs.client "attic"} watch-store ${lib.escapeShellArg "own:${cfg.cacheName}"}
        '';
      };
    })
  ];
}
