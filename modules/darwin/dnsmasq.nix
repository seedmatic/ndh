{ config, lib, pkgs, ... }: let
  user = config.profile.user;
  userName = user.name;
  logFile = "/Users/${userName}/Library/Logs/dnsmasq.log";

  dnsmasqActivationScript = pkgs.writeShellScript "dnsmasq-activation.sh" ''
    set -euo pipefail
    LOG="/var/log/darwin-dnsmasq-activation.log"
    {
      echo "[dnsmasq] Ensuring log path ${logFile}"
      mkdir -p "$(dirname ${logFile})"
      touch "${logFile}"
      chmod 644 "${logFile}"
      chown ${userName}:staff "${logFile}"
    } >>"$LOG" 2>&1
  '';
in {
  launchd.daemons.dnsmasq = lib.mkForce {
    serviceConfig = {
      Label = "org.nixos.dnsmasq";
      ProgramArguments = [
        "${pkgs.dnsmasq}/bin/dnsmasq"
        "--conf-file=/etc/dnsmasq.conf"
        "--keep-in-foreground"
        "--log-facility=${logFile}"
      ];
      RunAtLoad = false;
      KeepAlive = true;
    };
  };

  system.activationScripts.postActivation.text = ''
    ${dnsmasqActivationScript}
  '';
}