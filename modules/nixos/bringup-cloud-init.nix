{ config, lib, pkgs, ndh, ... }:
let
  ndhContext = ndh.context;

  # Cloud-init user-data for first-boot activation
  cloudInitUserData = pkgs.writeText "cloud-init-user-data.yaml" ''
    #cloud-config

    # First boot: fetch full system from remote store and activate
    runcmd:
      - |
        set -euxo pipefail

        # Read full system path and remote store URL from kernel cmdline
        FULL_SYSTEM=$(grep -oP 'ndh\.fullsystem=\K[^ ]+' /proc/cmdline || echo "")
        STORE_HOST=$(grep -oP 'ndh\.remotestore=\K[^ ]+' /proc/cmdline || echo "")

        if [ -z "$FULL_SYSTEM" ]; then
          echo "[cloud-init] WARN: No full system path in kernel params, staying on minimal system" >&2
          exit 0
        fi

        if [ -z "$STORE_HOST" ]; then
          echo "[cloud-init] ERROR: No remote store URL in kernel params" >&2
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

    # Mount xchg (shared via virtio-9p from preVM) as cloud-init seed directory.
    # preVM places user-data there before the VM starts.
    fileSystems."/var/lib/cloud/seed/nocloud" = {
      device = "xchg";
      fsType = "9p";
      options = [ "trans=virtio" "version=9p2000.L" "msize=16384" ];
      neededForBoot = true;
    };

    # Export cloud-init user-data via system.build for mkBringupZfsDiskImages
    system.build.cloudInitUserData = cloudInitUserData;
  };
}
