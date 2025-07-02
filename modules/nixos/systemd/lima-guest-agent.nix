{ config, modulesPath, pkgs, lib, ... }:

let
  LIMA_CIDATA_MNT = "/mnt/lima-cidata";
  LIMA_CIDATA_DEV = "/dev/disk/by-label/cidata";

in {
  imports = [];

  systemd.services.lima-guestagent =  {
    enable = true;
    description = "Forward ports to the lima-hostagent";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "lima-cloud-init.service" ];
    requires = [ "lima-cloud-init.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${LIMA_CIDATA_MNT}/lima-guestagent --debug daemon";
      Restart = "on-failure";
    };
  };

}
