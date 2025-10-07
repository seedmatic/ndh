{ config, pkgs, lib, ... }:

let
  LIMA_CIDATA_MNT = "/mnt/lima-cidata";
  # Use writeShellApplication so shebang is patched to Nix store bash and runtime inputs are explicit.
  startScriptDrv = pkgs.writeShellApplication {
    name = "lima-guest-agent-start";
    runtimeInputs = [ pkgs.coreutils pkgs.util-linux pkgs.bash ];
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
      ExecStart = "${startScriptDrv}/bin/lima-guest-agent-start";
      Restart = "on-failure";
      OOMPolicy = "continue";
      OOMScoreAdjust = "-500";
      User = "root";
    };
  };

}
