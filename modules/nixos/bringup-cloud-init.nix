{ config, lib, pkgs, ndh, ndhSystemd, ... }:
let
  ndhContext = ndh.context;

  # Full system path and remote store are baked in at eval time from ndh.context.
  # No /proc/cmdline parsing needed — values are embedded directly in user-data.
  fullSystem = ndhContext.runtimeSystemPath or "";
  remoteStore = ndhContext.remoteStore or "";
  # Single source of truth for the deployed nix-store identity path,
  # declared by modules/.common.d/nix-store-identity.nix. The
  # `nix-store.<host>` alias in 75-nix-store.conf binds both IdentityFile
  # and CertificateFile pointing under the same keyDir, and the deploy
  # script writes both files atomically — so checking keyPath is enough
  # to assert readiness.
  nixStoreKeyPath = config.nixStoreIdentity.keyPath;

  # Cloud-init user-data for first-boot activation. All ordering against
  # network-online + sops-install-secrets + ssh-keys-enrichment lives in the
  # cloud-final.service systemd drop-in configured by bringup-minimal-system.nix,
  # so the runcmd itself is free of wait-loops and can assume readiness.
  cloudInitUserData = pkgs.writeText "cloud-init-user-data.yaml" ''
    #cloud-config

    runcmd:
      - |
        set -euxo pipefail

        source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
        
        FULL_SYSTEM="${fullSystem}"
        STORE_HOST="${remoteStore}"
        SSH_KEY="${nixStoreKeyPath}"

        if [ -z "$FULL_SYSTEM" ]; then
          echo "[cloud-init] WARN: No full system path configured, staying on minimal system" >&2
          exit 0
        fi

        if [ -z "$STORE_HOST" ]; then
          echo "[cloud-init] ERROR: No remote store URL configured" >&2
          exit 1
        fi

        if [ ! -r "$SSH_KEY" ]; then
          echo "[cloud-init] ERROR: nix-store SSH key not found at $SSH_KEY (ssh-keys-enrichment.service should have materialized it)" >&2
          exit 1
        fi

        echo "[cloud-init] Fetching full system from $STORE_HOST: $FULL_SYSTEM"

        # The `nix-store.<host>` alias in /etc/ssh/ssh_config.d/75-nix-store.conf
        # supplies HostName, User, IdentityFile, CertificateFile, and
        # StrictHostKeyChecking=accept-new. Do not override any of those here —
        # forcing `-i` would drop the CertificateFile the alias binds and
        # cert-signed auth would silently fall back to bare key auth (which sshd
        # refuses under TrustedUserCAKeys + AuthorizedPrincipalsCommand).

        nix copy -L -v -v --no-check-sigs --from "$STORE_HOST" "$FULL_SYSTEM"

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
