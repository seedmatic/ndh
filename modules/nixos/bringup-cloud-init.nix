{ config, lib, pkgs, ndh, ndhSystemd, ... }:
let
  ndhContext = ndh.context;

  # Full system path and remote store are baked in at eval time from ndh.context.
  # No /proc/cmdline parsing needed — values are embedded directly in user-data.
  fullSystem = ndhContext.runtimeSystemPath or "";
  remoteStore = ndhContext.remoteStore or "";

  # Cloud-init user-data for first-boot activation. All ordering against
  # network-online + sops-install-secrets + ssh-keys-enrichment lives in the
  # cloud-final.service systemd drop-in configured by bringup-minimal-system.nix,
  # so the runcmd itself is free of wait-loops and can assume readiness.
  cloudInitUserData = pkgs.writeText "cloud-init-user-data.yaml" ''
    #cloud-config

    runcmd:
      - |
        set -euxo pipefail

        FULL_SYSTEM="${fullSystem}"
        STORE_HOST="${remoteStore}"
        SSH_KEY="/root/.ssh/nix-store"

        if [ -z "$FULL_SYSTEM" ]; then
          echo "[cloud-init] WARN: No full system path configured, staying on minimal system" >&2
          exit 0
        fi

        if [ -z "$STORE_HOST" ]; then
          echo "[cloud-init] ERROR: No remote store URL configured" >&2
          exit 1
        fi

        if [ ! -r "$SSH_KEY" ]; then
          echo "[cloud-init] ERROR: nix-store SSH key not found at $SSH_KEY" >&2
          exit 1
        fi

        echo "[cloud-init] Fetching full system from $STORE_HOST: $FULL_SYSTEM"

        # StrictHostKeyChecking=no on first boot — the remote host's public key
        # is not yet trusted. Tighten this once ssh-keys-enrichment also emits
        # a known_hosts fragment for the remote store host.
        export NIX_SSHOPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

        nix copy --from "$STORE_HOST" "$FULL_SYSTEM"

        echo "[cloud-init] Activating full system"
        "$FULL_SYSTEM/bin/switch-to-configuration" boot

        echo "[cloud-init] Full system activated, rebooting"
        systemctl reboot

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
