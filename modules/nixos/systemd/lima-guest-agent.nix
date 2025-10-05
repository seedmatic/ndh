{ config, pkgs, lib, ... }:

let
  LIMA_CIDATA_MNT = "/mnt/lima-cidata";
  startScript = pkgs.writeShellScriptBin "lima-guestagent-wrapper" ''
    exec ${./lima-guest-agent-start.sh}
  '';
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
      ExecStart = "${startScript}/bin/lima-guestagent-wrapper";
      Restart = "on-failure";
      OOMPolicy = "continue";
      OOMScoreAdjust = "-500";
      User = "root";
    };
  };

}
