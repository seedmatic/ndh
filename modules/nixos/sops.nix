{
  config,
  lib,
  pkgs,
  ...
}:
let
  hasManagedSecrets = (config.sops.secrets or { }) != { };
  bootstrapCfg = config.ndh.sopsAgeKeyBootstrap;
  keysTargetUnit = "keys.target";
  hasLimaCloudInitService = builtins.hasAttr "io-nxmatic-nix-darwin-home-lima-cloud-init" config.systemd.services;
  limaCloudInitUnitDeps = lib.optionals hasLimaCloudInitService [
    "io-nxmatic-nix-darwin-home-lima-cloud-init.service"
  ];
  importCandidateDirs = lib.unique (
    map builtins.dirOf (lib.filter (path: path != "") bootstrapCfg.nixosHostKeyImport.candidates)
  );
  bootstrapRequiredMountPaths = lib.unique ([ config.sops.age.keyFile ] ++ importCandidateDirs);
in
{
  config = {
    # NixOS policy: systemd-driven sops activation and host key import defaults.
    sops.useSystemdActivation = lib.mkDefault true;
    ndh.sopsAgeKeyBootstrap = {
      defaultAgeKeyFile = lib.mkDefault config.ndh.sopsAgeKeyBootstrap.systemWideKeyFile;
      nixosHostKeyImport.enable = lib.mkDefault true;
      nixosHostKeyImport.remoteFetch.enable = lib.mkDefault true;
    };

    # NixOS-only systemd ordering for SOPS key bootstrap before secret installation.
    systemd.services.${config.ndh.sopsAgeKeyBootstrap.systemdUnitName} =
      lib.mkIf (config.sops.useSystemdActivation or false)
        {
          description = "Ensure SOPS age key is available before sops-install-secrets (@codebase)";
          requires = [ keysTargetUnit ] ++ limaCloudInitUnitDeps;
          after = [ keysTargetUnit ] ++ limaCloudInitUnitDeps;
          before = [ "sops-install-secrets.service" ];
          wantedBy = [ "sops-install-secrets.service" ];
          unitConfig = lib.mkIf bootstrapCfg.nixosHostKeyImport.enable {
            RequiresMountsFor = bootstrapRequiredMountPaths;
          };
          serviceConfig = {
            Type = "oneshot";
            ExecStart = config.ndh.sopsAgeKeyBootstrap.systemdExecStartScript;
          };
        };

    systemd.services.sops-install-secrets =
      lib.mkIf ((config.sops.useSystemdActivation or false) && hasManagedSecrets)
        {
          requires = [
            keysTargetUnit
            "${config.ndh.sopsAgeKeyBootstrap.systemdUnitName}.service"
          ];
          after = [
            keysTargetUnit
            "${config.ndh.sopsAgeKeyBootstrap.systemdUnitName}.service"
          ];
          unitConfig.ConditionPathExists = config.sops.age.keyFile;
        };

    nixBashLogger.cmd = lib.mkDefault "${pkgs.util-linux}/bin/logger -p notice -t %TAG%";
  };
}
