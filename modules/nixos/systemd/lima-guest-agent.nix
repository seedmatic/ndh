{
  config,
  pkgs,
  lib,
  ndhSystemd,
  ...
}:

let
  LIMA_CIDATA_MNT = "/mnt/lima-cidata";
  isLimaProvider = config.ndh.vm.provider == "lima";
  contributedTargetName = ndhSystemd.contributedTargetName;
  # Use writeShellApplication to create a proper executable with dependencies
  startScript = pkgs.writeShellApplication {
    name = "lima-guest-agent-start";
    runtimeInputs = with pkgs; [
      util-linux
      bash
      yq-go
    ];
    text = builtins.readFile ./lima-guest-agent-start.sh;
    # Exclude SC1090 (can't follow dynamic source) as lima.env is provided at runtime
    excludeShellChecks = [ "SC1090" ];
  };
in
{
  imports = [ ];

  config = lib.mkIf isLimaProvider {
    systemd.services.${ndhSystemd.mkUnitName "lima-guestagent"} = {
      description = "Lima Guest Agent";
      wantedBy = [ contributedTargetName ];
      after = [ (ndhSystemd.mkServiceName "lima-cloud-init") ];
      requires = [ (ndhSystemd.mkServiceName "lima-cloud-init") ];
      unitConfig = {
        ConditionPathExists = "${LIMA_CIDATA_MNT}/lima-guestagent";
      };
      path = with pkgs; [
        util-linux
        yq-go
      ];
      serviceConfig = {
        Type = "simple";
        EnvironmentFile = "${LIMA_CIDATA_MNT}/lima.env";
        ExecStart = "${startScript}/bin/lima-guest-agent-start";
        Restart = "on-failure";
        OOMPolicy = "continue";
        OOMScoreAdjust = "-500";
        User = "root";
        # Ensure nix-ld environment is available for dynamically linked binaries
        Environment = [
          "NIX_LD=/run/current-system/sw/share/nix-ld/lib/ld-linux-x86-64.so.2"
          "NIX_LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib"
        ];
      };
    };
  };

}
