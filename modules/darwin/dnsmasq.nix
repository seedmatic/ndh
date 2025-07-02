{ config, lib, pkgs, ... }: let
  user = config.profile.user;
  userName = user.name;
  logFile = "/Users/${userName}/Library/Logs/dnsmasq.log";
in {
  launchd.daemons.dnsmasq = lib.mkForce {
    serviceConfig = {
      Label = "org.nixos.dnsmasq";
      ProgramArguments = [
        "${pkgs.dnsmasq}/bin/dnsmasq"
        "--conf-file=/etc/dnsmasq.conf"
        "--keep-in-foreground"
      ];
      RunAtLoad = true;
      KeepAlive = true;
    };
  };

  system.activationScripts.dnsmasqLogFile = lib.stringAfter ["users"] ''
    mkdir -p "$(dirname ${logFile})"
    touch "${logFile}"
    chmod 644 "${logFile}"
    chown ${userName}:staff "${logFile}"
  '';
}