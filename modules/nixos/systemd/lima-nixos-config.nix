{
  config,
  pkgs,
  lib,
  ndhSystemd,
  ...
}:
let
  # Build helper binary from repository script (no inline bash to avoid interpolation issues)
  limaNixosConfigPkg = pkgs.writeShellScriptBin "lima-nixos-config" (
    builtins.readFile ./lima-nixos-config.sh
  );

  # Whether we might need network (only if cloning is allowed at runtime). We can't know env at build
  # so we keep network dependency minimal; remove strict requires.
  needsNetwork = false; # linking is primary path; cloning optional & user-triggered

  baseAfter = [
    "local-fs.target"
    (ndhSystemd.mkServiceName "lima-cloud-init")
  ];
  afterList = baseAfter ++ lib.optional needsNetwork "network-online.target";
  isLimaProvider = config.ndh.vm.provider == "lima";
  contributedTargetName = ndhSystemd.contributedTargetName;

in
{
  config = lib.mkIf isLimaProvider {
    systemd.services.${ndhSystemd.mkUnitName "lima-nixos-config"} = {
      description = "Link (preferred) or optionally clone NixOS darwin home repo for Lima host";

      # Only need cloud-init first (mounts, user home). Network not strictly required for linking.
      after = afterList;
      wants = [ (ndhSystemd.mkServiceName "lima-cloud-init") ];

      # Don't hard require network or resolvconf anymore; cloning is fallback and user-controlled.
      wantedBy = [ contributedTargetName ];

      path = with pkgs; [
        coreutils
        git
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${limaNixosConfigPkg}/bin/lima-nixos-config ${config.limaHost.hostName}";
        TimeoutStartSec = 60;
      };

      # Skip running if flake already linked (negative condition prevents re-run each boot)
      unitConfig = {
        X-StopOnRemoval = false;
        RequiresMountsFor = [
          "/var/lib/git"
        ];
        ConditionPathExists = "!/etc/nixos/flake.nix"; # run only if missing
      };
    };
  };
}
