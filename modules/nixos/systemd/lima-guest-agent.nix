{ config, pkgs, lib, ... }:

let
  LIMA_CIDATA_MNT = "/mnt/lima-cidata";
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
      ExecStart = "${LIMA_CIDATA_MNT}/lima-guestagent daemon --debug=\${LIMA_CIDATA_DEBUG} --vsock-port=\${LIMA_CIDATA_VSOCK_PORT} --virtio-port=\${LIMA_CIDATA_VIRTIO_PORT}";
      Restart = "on-failure";
      OOMPolicy = "continue";
      OOMScoreAdjust = "-500";
      User = "root";
    };
  };

}
