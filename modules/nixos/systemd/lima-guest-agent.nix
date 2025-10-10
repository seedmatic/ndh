{ config, pkgs, lib, ... }:

let
  LIMA_CIDATA_MNT = "/mnt/lima-cidata";
  # Use writeShellApplication to create a proper executable with dependencies
  startScript = pkgs.writeShellApplication {
    name = "lima-guest-agent-start";
    runtimeInputs = with pkgs; [ util-linux bash ];
    text = builtins.readFile ./lima-guest-agent-start.sh;
  };
in {
  imports = [];

  systemd.services.lima-guestagent = {
    description = "Lima Guest Agent";
    wantedBy = [ "multi-user.target" ];
    after = [ "lima-cloud-init.service" ];
    requires = [ "lima-cloud-init.service" ];
    path = with pkgs; [ util-linux ];
    serviceConfig = {
      Type = "simple";
      EnvironmentFile = "${LIMA_CIDATA_MNT}/lima.env";
      ExecStart = "${startScript}/bin/lima-guest-agent-start";
      Restart = "on-failure";
      OOMPolicy = "continue";
      OOMScoreAdjust = "-500";
      User = "root";
    };
  };

}
