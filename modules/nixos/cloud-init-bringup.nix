{ config, lib, pkgs, ndh, ... }:
let
  ndhContext = ndh.context;

  # Full system store path to activate (set by mkNixosOutputs)
  fullSystemPath = ndhContext.fullSystemPath or "";

  # Remote store URL to fetch from (darwin host)
  remoteStoreUrl = ndhContext.remoteStoreUrl or "ssh://builder@bioskop.local";

  # Extract hostname from SSH URL for ping test
  extractHostname = url:
    let
      matches = builtins.match "ssh://([^@]+@)?([^/:]+)(:[0-9]+)?(/.*)?|.*" url;
    in
      if matches != null && builtins.length matches > 1
      then builtins.elemAt matches 1
      else url;

  storeHostname = extractHostname remoteStoreUrl;

  # Cloud-init user-data for first-boot activation
  cloudInitUserData = pkgs.writeText "cloud-init-user-data.yaml" ''
    #cloud-config

    # First boot: fetch full system from remote store and activate
    runcmd:
      - |
        set -euxo pipefail

        # Wait for network
        timeout=60
        while ! ping -c 1 ${storeHostname} >/dev/null 2>&1; do
          sleep 1
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "[cloud-init] ERROR: network timeout waiting for ${storeHostname}" >&2
            exit 1
          fi
        done

        # Remote store URL
        STORE_HOST="${remoteStoreUrl}"

        # Full system store path
        FULL_SYSTEM="${fullSystemPath}"

        if [ -z "$FULL_SYSTEM" ]; then
          echo "[cloud-init] WARN: No full system path configured, staying on minimal system" >&2
          exit 0
        fi

        # Wait for SSH key extraction service
        timeout=30
        while ! systemctl is-active --quiet bringup-extract-ssh-key.service; do
          sleep 1
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "[cloud-init] ERROR: SSH key extraction service did not complete" >&2
            exit 1
          fi
        done

        # Verify SSH key exists
        SSH_KEY="/root/.ssh/rke2-cluster"
        if [ ! -r "$SSH_KEY" ]; then
          echo "[cloud-init] ERROR: SSH key not found at $SSH_KEY" >&2
          exit 1
        fi

        echo "[cloud-init] Fetching full system from $STORE_HOST: $FULL_SYSTEM"

        # Configure SSH to use the extracted key and disable strict host key checking for first boot
        export NIX_SSHOPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

        nix copy --from "$STORE_HOST" "$FULL_SYSTEM" || {
          echo "[cloud-init] ERROR: Failed to fetch full system" >&2
          exit 1
        }

        echo "[cloud-init] Activating full system"

        # Activate the full system
        "$FULL_SYSTEM/bin/switch-to-configuration" boot || {
          echo "[cloud-init] ERROR: Failed to activate full system" >&2
          exit 1
        }

        echo "[cloud-init] Full system activated, rebooting"
        systemctl reboot

    # Disable cloud-init after first boot
    final_message: "Cloud-init bringup complete"
  '';
in
{
  # Only configure cloud-init in minimal bringup mode
  config = lib.mkIf (ndhContext.generationMode == "bringup") {
    # Install cloud-init user-data
    environment.etc."cloud/cloud.cfg.d/99-bringup.cfg".text = ''
      datasource_list: [ NoCloud ]
      datasource:
        NoCloud:
          fs_label: cidata
          seedfrom: file:///var/lib/cloud/seed/nocloud/
    '';

    # Seed directory with user-data
    systemd.tmpfiles.rules = [
      "d /var/lib/cloud/seed 0755 root root -"
      "d /var/lib/cloud/seed/nocloud 0755 root root -"
      "L+ /var/lib/cloud/seed/nocloud/user-data - - - - ${cloudInitUserData}"
    ];
  };
}
