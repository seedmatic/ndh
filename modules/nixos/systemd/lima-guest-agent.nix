{ config, pkgs, lib, ... }:

let
  LIMA_CIDATA_MNT = "/mnt/lima-cidata";
  # Use writeShellScript for proper executable creation
  startScript = pkgs.writeShellScript "lima-guest-agent-start" (builtins.readFile ./lima-guest-agent-start.sh);
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
      ExecStart = "${startScript}";
      Restart = "on-failure";
      OOMPolicy = "continue";
      OOMScoreAdjust = "-500";
      User = "root";
    };
  };

}
