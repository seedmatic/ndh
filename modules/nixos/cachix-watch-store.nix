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

    # cachix-watch-store keeps an open client connection to nix-daemon
    # for the lifetime of the unit; on shutdown the upstream module
    # has no ordering against nix-daemon.service, so systemd stops
    # both in parallel and `cachix watch-store` wedges on the dying
    # daemon socket.  Operator-visible symptom is systemd-shutdown
    # printing `Waiting for process: <pid> (nix-daemon), <pid>
    # (cachix)` and blocking until TimeoutStopSec expires (default
    # 90s).  Make the ordering explicit and cap the worst case at
    # 10s so a wedged cachix never blocks reboot for more than that.
    systemd.services.cachix-watch-store = {
      after = [ "nix-daemon.service" ];
      requires = [ "nix-daemon.service" ];
      serviceConfig.TimeoutStopSec = 10;
    };
  };
}
