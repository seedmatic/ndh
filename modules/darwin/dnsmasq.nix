{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.profile.user;
  userName = user.name;
  logFile = "/Users/${userName}/Library/Logs/dnsmasq.log";

  dnsmasqActivationScript = pkgs.runCommand "dnsmasq-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./dnsmasq.d/post-activation.sh {
        logFile = logFile;
        userName = userName;
      }
    } "$out"
    chmod +x "$out"
  '';
in
{
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
