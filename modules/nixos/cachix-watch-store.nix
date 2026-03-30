{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nxmaticCachixWatchStore;
  tokenSecretName = "nxmatic-cachix-watch-store-token";
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
  };
}
