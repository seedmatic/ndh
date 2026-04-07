{
  config,
  pkgs,
  lib,
  ...
}:
let

  dollar = "$";

in
lib.mkIf config.rescue.enable {
  boot.kernelParams = [
    "rd.systemd.unit=rescue.target"
    "rd.systemd.debug_shell=1"
    "systemd.unit=rescue.target"
  ];

  environment.systemPackages = with pkgs; [
    # Rescue mode tools
    ddrescue
    gptfdisk
    parted
    testdisk
    smartmontools
    pciutils
    usbutils
    lshw
  ];

  # Additional system checks
  systemd.services.io-nxmatic-nix-darwin-home-rescue-checks = {
    description = "Perform rescue mode system checks";
    wantedBy = [ "rescue.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeScript "rescue-checks" ''
        #!${pkgs.bash}/bin/bash
        echo "Performing rescue mode system checks..."
        ${pkgs.coreutils}/bin/df -h
        ${pkgs.procps}/bin/free -h
        ${pkgs.iproute2}/bin/ip a
      '';
    };
  };

}
