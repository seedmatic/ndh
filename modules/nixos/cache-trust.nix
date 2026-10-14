{
  config,
  lib,
  ...
}:
# NixOS wiring for the fleet cache signing compose step.
#
# Runs as a systemd oneshot ordered After sops-install-secrets.service
# (which deploys the bare private bytes to /run/secrets/<name>.key.bare)
# and Before nix-daemon.service (which needs the wire-format key file
# at /etc/nix/<name>.key on first lookup of secret-key-files).
#
# The compose script itself and the fleet trust settings come from
# modules/.common.d/cache-trust.nix.
{
  # A key whose content changes under the same name touches neither this unit nor nix.conf: sops-nix
  # reruns the compose and restarts nix-daemon, which reads secret-key-files once, at start.
  config.sops.secrets = lib.listToAttrs (
    map (
      name:
      lib.nameValuePair "${name}.key.bare" {
        restartUnits = [
          "cache-trust-compose.service"
          "nix-daemon.service"
        ];
      }
    ) config.ndh.cacheTrust.cachixNames
  );

  config.systemd.services.cache-trust-compose = {
    description = "Compose fleet cache signing keys from SOPS-deployed bare values (@codebase)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
    before = [ "nix-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      Group = "root";
      ExecStart = "${config.ndh.cacheTrust.composeScript}/bin/cache-trust-compose";
    };
  };
}
