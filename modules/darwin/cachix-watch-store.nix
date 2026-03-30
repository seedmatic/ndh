# Darwin backend for nxmatic Cachix watch-store (@codebase)
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.nxmaticCachixWatchStore;
  secretNamespaceDir = "/run/secrets/nix-darwin-home";
  tokenSecretName = "nxmatic-cachix-watch-store.token";
  tokenSecretPath = config.sops.secrets.${tokenSecretName}.path;

  watchStoreScript = pkgs.writeShellScript "nxmatic-cachix-watch-store" ''
    set -euo pipefail

    token_file="${tokenSecretPath}"
    if [ ! -r "$token_file" ]; then
      echo "cachix token file not readable: $token_file"
      exit 0
    fi

    export CACHIX_AUTH_TOKEN="$(cat "$token_file")"

    cmd=("${pkgs.cachix}/bin/cachix" "watch-store" "${cfg.cacheName}")
    ${optionalString (cfg.jobs != null) ''
      cmd+=("--jobs" "${toString cfg.jobs}")
    ''}
    ${optionalString (cfg.compressionLevel != null) ''
      cmd+=("--compression-level" "${toString cfg.compressionLevel}")
    ''}
    ${optionalString (cfg.signingKeyFile != null) ''
      cmd+=("--signing-key-file" "${cfg.signingKeyFile}")
    ''}
    ${optionalString cfg.verbose ''
      cmd+=("--verbose")
    ''}

    exec "''${cmd[@]}"
  '';
in
{
  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      cachix
    ];

    sops.secrets.${tokenSecretName} = {
      format = "yaml";
      sopsFile = cfg.sopsEncryptedTokenFile;
      key = "cachix/${cfg.cacheName}/token";
      path = "${secretNamespaceDir}/${tokenSecretName}";
    };

    launchd.daemons.nxmatic-cachix-watch-store = {
      script = "${watchStoreScript}";
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 30;
        StandardOutPath = "/var/log/nxmatic-cachix-watch-store.log";
        StandardErrorPath = "/var/log/nxmatic-cachix-watch-store.log";
      };
    };
  };
}
