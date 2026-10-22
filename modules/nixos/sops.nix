{
  config,
  options,
  lib,
  pkgs,
  ndhSystemd,
  worktreePath,
  ndh,
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
  bootstrapUnit = "${bootstrapCfg.systemdUnitName}.service";
  # Every unit that reads a secret, computed from the configuration rather than listed: those ordered
  # after or requiring sops-install-secrets, and those a secret names in its restartUnits.
  secretReaders = lib.unique (
    lib.filter (unit: unit != "sops-install-secrets.service" && unit != bootstrapUnit) (
      lib.mapAttrsToList (name: _: "${name}.service") (
        lib.filterAttrs (
          _: svc:
          builtins.elem "sops-install-secrets.service" (
            (svc.after or [ ]) ++ (svc.requires or [ ]) ++ (svc.wants or [ ]) ++ (svc.bindsTo or [ ])
          )
        ) config.systemd.services
      )
      ++ lib.concatMap (secret: secret.restartUnits or [ ]) (lib.attrValues (config.sops.secrets or { }))
    )
  );
  # The machine's sops identity, from keys.yaml (roles × keys K5): its own served host key once its current slot is
  # `serving` and was born on it (`origin: host`), as the darwin hosts do; until then the age identity placed at its
  # keyFile, read as before. Never a pushed key: the push channel is gone.
  roles = import ../.common.d/host-key.d/slots.nix { inherit lib; } config.ndh.hostKey.entry;
  ownSopsKey = (roles.current.state or "") == "serving" && (roles.current.origin or "") == "host";
in
{
  # The age-bootstrap service imports keys from the host-provided virtiofs
  # mount (/srv/host/sops.d) when running under Tart. Pull that mount unit in
  # here so bringup-minimal picks it up transitively from sops.nix, without
  # needing to import the full systemd/ aggregator.
  imports = [
    ./systemd/tart-host-shares.nix
    (worktreePath.of "modules/.common.d/host-key.nix")
  ];

  config = {
    # The age identity's directory is root's alone, whatever umask made it: a file left beside the key (an editor's
    # autosave was found there on nikopol-nixos, 2026-10-18) must not be readable by another account.
    systemd.tmpfiles.rules = lib.mkIf (config.sops.age.keyFile != null) [
      "d ${builtins.dirOf config.sops.age.keyFile} 0700 root root -"
    ];

    # NixOS policy: systemd-driven sops activation and host key import defaults.
    sops.useSystemdActivation = lib.mkDefault true;
    ndh.sopsAgeKeyBootstrap = {
      defaultAgeKeyFile = lib.mkDefault config.ndh.sopsAgeKeyBootstrap.systemWideKeyFile;
      nixosHostKeyImport.enable = lib.mkDefault true;
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
          # The runtime profile (age-keygen) is seeded by activation and by the
          # tmpfiles `L+` rule; tmpfiles-setup runs before sysinit, so ordering
          # on it keeps this unit inside the early-boot phase.
          after = [
            keysTargetUnit
            "systemd-tmpfiles-setup.service"
          ]
          ++ localFsUnitDeps;
          before = [ "sops-install-secrets.service" ];
          wantedBy = [ "sops-install-secrets.service" ];
          # sops-nix runs sops-install-secrets before sysinit.target with
          # DefaultDependencies=no; default dependencies here would order this
          # unit after sysinit/basic and close a cycle that systemd breaks by
          # dropping jobs, leaving /run/secrets empty.
          unitConfig = {
            DefaultDependencies = false;
          }
          // lib.optionalAttrs bootstrapCfg.nixosHostKeyImport.enable {
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
          # Not gated on the key file's existence: the bootstrap unit before it fails loudly when the identity
          # is missing.
        };

    # Born on the machine and served: sops opens its files with that key, the files' recipients name its age (R1).
    sops.age = lib.mkIf ownSopsKey {
      keyFile = lib.mkForce null;
      sshKeyPaths = lib.mkForce [ config.ndh.hostKey.servedKeyFile ];
    };

  };
}
