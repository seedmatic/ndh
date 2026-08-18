{
  config,
  options,
  lib,
  pkgs,
  ndhSystemd,
  ...
}:
let
  hasManagedSecrets = (config.sops.secrets or { }) != { };
  bootstrapCfg = config.ndh.sopsAgeKeyBootstrap;
  keysTargetUnit = "keys.target";
  localFsUnitDeps = [ "local-fs.target" ];
  importCandidateDirs = lib.unique (
    map builtins.dirOf (lib.filter (path: path != "") bootstrapCfg.nixosHostKeyImport.candidates)
  );
  bootstrapRequiredMountPaths = lib.unique ([ config.sops.age.keyFile ] ++ importCandidateDirs);
in
{
  # The age-bootstrap service imports keys from the host-provided virtiofs
  # mount (/srv/host/sops.d) when running under Tart. Pull that mount unit in
  # here so bringup-minimal picks it up transitively from sops.nix, without
  # needing to import the full systemd/ aggregator.
  imports = [ ./systemd/tart-host-shares.nix ];

  config = {
    # NixOS policy: systemd-driven sops activation and host key import defaults.
    sops.useSystemdActivation = lib.mkDefault true;
    ndh.sopsAgeKeyBootstrap = {
      defaultAgeKeyFile = lib.mkDefault config.ndh.sopsAgeKeyBootstrap.systemWideKeyFile;
      nixosHostKeyImport.enable = lib.mkDefault true;
      nixosHostKeyImport.remoteFetch.enable = lib.mkDefault true;
      # Prefix the unit name so it groups with the other NDH systemd services
      # (mkUnitName is a no-op if the prefix is already present, so downstream
      # overrides remain effective).
      systemdUnitName = lib.mkDefault (ndhSystemd.mkUnitName "sops-age-bootstrap");
    };

    # NixOS-only systemd ordering for SOPS key bootstrap before secret installation.
    systemd.services.${config.ndh.sopsAgeKeyBootstrap.systemdUnitName} =
      lib.mkIf (config.sops.useSystemdActivation or false)
        {
          description = "Ensure SOPS age key is available before sops-install-secrets (@codebase)";
          requires = [ keysTargetUnit ] ++ localFsUnitDeps;
          after = [ keysTargetUnit ] ++ localFsUnitDeps;
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
          # Do not gate this unit on key-file existence: bootstrap is responsible
          # for creating/importing the key before install runs.
        };

  };
}
