{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nxmaticCachixWatchStore;
  secretNamespaceDir = "/run/secrets/nix-darwin-home";
  tokenSecretName = "nxmatic-cachix-watch-store.token";
  tokenSecretPath = config.sops.secrets.${tokenSecretName}.path;
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      cachix
    ];

    sops.secrets.${tokenSecretName} = {
      format = "yaml";
      sopsFile = cfg.sopsEncryptedTokenFile;
      key = "cachix/${cfg.cacheName}/token";
      path = "${secretNamespaceDir}/${tokenSecretName}";
    };

    services.cachix-watch-store = {
      enable = true;
      cacheName = cfg.cacheName;
      cachixTokenFile = tokenSecretPath;
      signingKeyFile = cfg.signingKeyFile;
      compressionLevel = cfg.compressionLevel;
      jobs = cfg.jobs;
      verbose = cfg.verbose;
    };

    # cachix-watch-store-agent keeps an open client connection to
    # nix-daemon for the lifetime of the unit; on shutdown the upstream
    # module has no ordering against nix-daemon.service, so systemd
    # stops both in parallel and `cachix watch-store` wedges on the
    # dying daemon socket.  Worse, upstream sets KillMode=process so
    # only the main PID gets SIGTERM, leaving child cachix workers
    # parented to PID1 ignoring the stop signal entirely.  Operator-
    # visible symptom is systemd-shutdown printing
    # `Waiting for process: <pid> (cachix)` and blocking until
    # TimeoutStopSec expires (default 90s).
    #
    # Override the right unit (note: upstream names it
    # `cachix-watch-store-agent`, not `cachix-watch-store`), force a
    # full control-group kill so the workers go down with the leader,
    # add explicit nix-daemon ordering, and cap the worst case at 10s.
    systemd.services.cachix-watch-store-agent = {
      after = [ "nix-daemon.service" ];
      requires = [ "nix-daemon.service" ];
      serviceConfig = {
        KillMode = lib.mkForce "control-group";
        TimeoutStopSec = 10;
      };
    };
  };
}
