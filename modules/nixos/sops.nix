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
  hostKeyReaders = [
    "sshd.service"
  ]
  ++ lib.optional config.services.tailscale.enable "tailscaled.service";
  identityReload = pkgs.writeShellApplication {
    name = "ndh-identity-reload";
    text = ''
      # After the operator placed an identity: one command instead of restarting units by name.
      ${config.systemd.package}/bin/systemctl restart ${bootstrapUnit}
      ${config.systemd.package}/bin/systemctl restart sops-install-secrets.service
      ${lib.optionalString (
        secretReaders != [ ]
      ) "${config.systemd.package}/bin/systemctl restart ${lib.concatStringsSep " " secretReaders}"}
      echo "[ndh-identity-reload] sops and its readers restarted: ${lib.concatStringsSep " " secretReaders}"
      ${lib.optionalString config.ndh.hostKey.own ''
        # The push placed a new host key under them, and both read it only at start.
        ${config.systemd.package}/bin/systemctl try-restart ${lib.concatStringsSep " " hostKeyReaders}
        echo "[ndh-identity-reload] host key readers restarted: ${lib.concatStringsSep " " hostKeyReaders}"
      ''}
    '';
  };
  # The machine's side of ndh-identity-push: places what bioskop sends, then ndh-identity-reload.
  identityPush = import ../.common.d/identity-push.d/package.nix { inherit pkgs lib; };
  machine = config.networking.hostName;
  # The operator seat whose guest this is: its host key gives this machine's age identity (its access point).
  baremetal = ndh.context.catalog.netplan.baremetal;
  seat = lib.findFirst (h: baremetal.${h}.nixosHostname == machine) null (lib.attrNames baremetal);
  identityReceive = identityPush.receive {
    inherit machine;
    keyFile = config.sops.age.keyFile;
    sshfs = config.services.sshfsMounts.enable;
    served =
      if config.ndh.hostKey.own then config.ndh.hostKey.file else "/etc/ssh/ssh_host_ed25519_key.pub";
    owner = "root:root";
    recorded = {
      hostKey = identityPush.recordedPublic config.ndh.keysYaml.keys "host-${machine}";
      sshfsKey = identityPush.recordedPublic config.ndh.keysYaml.keys "sshfs-${machine}";
      accessPoint =
        if seat == null then "" else identityPush.recordedPublic config.ndh.keysYaml.keys "host-${seat}";
    };
  };
in
{
  # The age-bootstrap service imports keys from the host-provided virtiofs
  # mount (/srv/host/sops.d) when running under Tart. Pull that mount unit in
  # here so bringup-minimal picks it up transitively from sops.nix, without
  # needing to import the full systemd/ aggregator.
  imports = [
    ./systemd/tart-host-shares.nix
    (worktreePath.of "modules/.common.d/host-key.nix")
    # Whether the frame carries the sshfs key: declared wherever the receive is, the bringup included.
    ./sshfs-mounts.nix
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
          # Not gated on the key file's existence: the bootstrap unit before it fails loudly when the
          # identity is missing, and ndh-identity-reload restarts both once the operator placed it.
        };

    environment.systemPackages =
      lib.mkIf ((config.sops.useSystemdActivation or false) && hasManagedSecrets)
        [
          identityReload
          identityReceive
        ];

  };
}
