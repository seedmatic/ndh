{
  config,
  pkgs,
  lib,
  ndh,
  ndhSystemd,
  ...
}:

let
  ndhContext = ndh.context;
  bringupMode = ndhContext.generationMode == "bringup";
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";

  # On the root dataset, so it survives the reboot it triggers.  Deliberately not
  # under /etc: NixOS owns /etc, and this file is written by the nested-VM
  # installer into the target root long before any generation activates.
  targetFile = "/var/lib/ndh/bringup-target-system";
  attemptFile = "/var/lib/ndh/bringup-target-system.attempted";

  activateScript =
    ndh.store.runCommand "ndh-bringup-target-activate"
      {
        passAsFile = [ "text" ];
        text =
          builtins.replaceStrings
            [
              "@nixBashTrampoline@"
              "@targetFile@"
              "@attemptFile@"
              "@loggerTag@"
            ]
            [
              nixBashTrampoline
              targetFile
              attemptFile
              "nixos.systemd.bringupTargetActivate"
            ]
            (builtins.readFile ./bringup-target-activate.sh);
      }
      ''
        mkdir -p "$out/bin"
        {
          printf '%s\n' '#!${pkgs.bash}/bin/bash'
          tail -n +2 "$textPath"
        } > "$out/bin/ndh-bringup-target-activate"
        chmod 0555 "$out/bin/ndh-bringup-target-activate"
      '';
in
{
  config = lib.mkIf bringupMode {
    systemd.services.${ndhSystemd.mkUnitName "bringup-target-activate"} = {
      description = "Activate the system this node was provisioned for, then reboot (@codebase)";

      wantedBy = [ ndhSystemd.contributedTargetName ];

      # The trampoline this script sources needs the NDH bringup-runtime profile,
      # which bringup-runtime.nix installs from its own boot oneshot.
      after = [
        "local-fs.target"
        "io-seedmatic-ndh-bringup-runtime-install.service"
      ];
      wants = [ "io-seedmatic-ndh-bringup-runtime-install.service" ];

      unitConfig = {
        # No declared target means this image was not provisioned for one — a
        # plain bringup, which must stay a bringup.  Skipping beats a unit that
        # fails on every boot of every such node.
        ConditionPathExists = targetFile;
        X-StopOnRemoval = false;
      };

      path = [
        pkgs.bash
        pkgs.coreutils
        config.nix.package
        config.systemd.package
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${activateScript}/bin/ndh-bringup-target-activate";
      };
    };
  };
}
