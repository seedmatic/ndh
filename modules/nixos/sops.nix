{ config, lib, pkgs, ... }:
let
  hasManagedSecrets = (config.sops.secrets or { }) != { };
in
{
  config = {
    # NixOS policy: systemd-driven sops activation and host key import defaults.
    sops.useSystemdActivation = lib.mkDefault true;
    nxmatic.sopsAgeKeyBootstrap = {
      defaultAgeKeyFile = lib.mkDefault config.nxmatic.sopsAgeKeyBootstrap.systemWideKeyFile;
      nixosHostKeyImport.enable = lib.mkDefault true;
      nixosHostKeyImport.remoteFetch.enable = lib.mkDefault true;
    };

    # NixOS-only systemd ordering for SOPS key bootstrap before secret installation.
    systemd.services.${config.nxmatic.sopsAgeKeyBootstrap.systemdUnitName} = lib.mkIf (config.sops.useSystemdActivation or false) {
      description = "Ensure SOPS age key is available before sops-install-secrets (@codebase)";
      before = [ "sops-install-secrets.service" ];
      wantedBy = [ "sops-install-secrets.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = config.nxmatic.sopsAgeKeyBootstrap.systemdExecStartScript;
      };
    };

    systemd.services.sops-install-secrets = lib.mkIf ((config.sops.useSystemdActivation or false) && hasManagedSecrets) {
      requires = [ "${config.nxmatic.sopsAgeKeyBootstrap.systemdUnitName}.service" ];
      after = [ "${config.nxmatic.sopsAgeKeyBootstrap.systemdUnitName}.service" ];
      unitConfig.ConditionPathExists = config.sops.age.keyFile;
    };

    activation.loggerCmd = lib.mkDefault "${pkgs.util-linux}/bin/logger -p notice -t %TAG%";
  };
}