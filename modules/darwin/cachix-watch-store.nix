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

  tokenSyncScript = pkgs.writeShellScript "nxmatic-cachix-token-sync" ''
    set -euo pipefail

    dst="${cfg.tokenFile}"
    enc_src="${toString cfg.sopsEncryptedTokenFile}"
    key_file="${cfg.sopsAgeKeyFile}"

    if [ ! -r "$enc_src" ]; then
      echo "sops encrypted token file not readable: $enc_src"
      rm -f "$dst"
      exit 0
    fi

    if [ ! -r "$key_file" ]; then
      echo "sops age key file not readable: $key_file"
      rm -f "$dst"
      exit 0
    fi

    token="$(${pkgs.sops}/bin/sops --decrypt --input-type yaml --output-type yaml "$enc_src" \
      | ${pkgs.yq-go}/bin/yq -r '.cachix.${cfg.cacheName}.token // ""' - 2>/dev/null || true)"

    if [ -z "$token" ] || [ "$token" = "null" ]; then
      echo "cachix token missing for cache '${cfg.cacheName}'"
      rm -f "$dst"
      exit 0
    fi

    install -d -m 0700 "$(dirname "$dst")"
    umask 0077
    printf '%s' "$token" > "$dst"
    chmod 0600 "$dst"
  '';

  watchStoreScript = pkgs.writeShellScript "nxmatic-cachix-watch-store" ''
    set -euo pipefail

    token_file="${cfg.tokenFile}"
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
      sops
      yq-go
    ];

    system.activationScripts.nxmaticCachixWatchStore.text = lib.mkAfter ''
      ${tokenSyncScript} || true
    '';

    launchd.daemons.nxmatic-cachix-token-sync = {
      script = "${tokenSyncScript}";
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = false;
        StartInterval = 300;
        StandardOutPath = "/var/log/nxmatic-cachix-token-sync.log";
        StandardErrorPath = "/var/log/nxmatic-cachix-token-sync.log";
        EnvironmentVariables = {
          SOPS_AGE_KEY_FILE = cfg.sopsAgeKeyFile;
        };
      };
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
