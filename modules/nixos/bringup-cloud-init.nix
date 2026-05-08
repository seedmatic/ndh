{ config, lib, pkgs, ndh, ... }:
let
  ndhContext = ndh.context;

  # Full system path and remote store are baked in at eval time from ndh.context.
  # No /proc/cmdline parsing needed — values are embedded directly in user-data.
  fullSystem = ndhContext.runtimeSystemPath or "";
  remoteStore = ndhContext.remoteStore or "";

  # Cloud-init user-data for first-boot activation
  cloudInitUserData = pkgs.writeText "cloud-init-user-data.yaml" ''
    #cloud-config

    # First boot: fetch full system from remote store and activate
    runcmd:
      - |
        set -euxo pipefail

        FULL_SYSTEM="${fullSystem}"
        STORE_HOST="${remoteStore}"

        if [ -z "$FULL_SYSTEM" ]; then
          echo "[cloud-init] WARN: No full system path configured, staying on minimal system" >&2
          exit 0
        fi

        if [ -z "$STORE_HOST" ]; then
          echo "[cloud-init] ERROR: No remote store URL configured" >&2
          exit 1
        fi

        # Extract hostname from SSH URL for ping test (ssh://user@host -> host)
        STORE_HOSTNAME=$(echo "$STORE_HOST" | sed -E 's|ssh://([^@]+@)?([^/:]+).*|\2|')

        # Wait for network
        timeout=60
        while ! ping -c 1 "$STORE_HOSTNAME" >/dev/null 2>&1; do
          sleep 1
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "[cloud-init] ERROR: network timeout waiting for $STORE_HOSTNAME" >&2
            exit 1
          fi
        done

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

    # cloud-init nocloud seed directory is pre-populated during disk image build
    # (bringup-zfs-disk-images-install.sh copies user-data/meta-data into it).
    # We just ensure the directory exists in case cloud-init runs before it is created.
    systemd.tmpfiles.rules = [
      "d /var/lib/cloud/seed/nocloud 0755 root root -"
    ];

    # Export cloud-init user-data via system.build for mkBringupZfsDiskImages
    system.build.cloudInitUserData = cloudInitUserData;
  };
}
