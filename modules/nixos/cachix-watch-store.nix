{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nxmaticCachixWatchStore;
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      cachix
      sops
      yq-go
    ];

    systemd.tmpfiles.rules = [
      "d /var/lib/cachix-watch-store 0700 root root -"
    ];

    systemd.services.nxmatic-cachix-token-sync = {
      description = "Extract nxmatic Cachix token from SOPS secrets file";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      before = [ "cachix-watch-store-agent.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
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
      environment = {
        SOPS_AGE_KEY_FILE = cfg.sopsAgeKeyFile;
      };
    };

    services.cachix-watch-store = {
      enable = true;
      cacheName = cfg.cacheName;
      cachixTokenFile = cfg.tokenFile;
      signingKeyFile = cfg.signingKeyFile;
      compressionLevel = cfg.compressionLevel;
      jobs = cfg.jobs;
      verbose = cfg.verbose;
    };

    systemd.services.cachix-watch-store-agent = {
      wants = [ "nxmatic-cachix-token-sync.service" ];
      after = [ "nxmatic-cachix-token-sync.service" ];
      unitConfig.ConditionPathExists = cfg.tokenFile;
    };
  };
}
