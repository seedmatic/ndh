{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  user = config.profile.user;
  userName = user.name;
  logFile = "/Users/${userName}/Library/Logs/dnsmasq.log";
  loggerScript = config.nixBashLogger.script;

  dnsmasqActivationScript = pkgs.runCommand (ndh.store.prefixedName "dnsmasq-post-activation.sh") { } ''
    cp ${
      pkgs.replaceVars ./dnsmasq.d/post-activation.sh {
        logFile = logFile;
        userName = userName;
        logger = loggerScript;
      }
    } "$out"
    chmod +x "$out"
  '';
in
{
  launchd.daemons.dnsmasq = lib.mkForce {
    serviceConfig = {
      Label = "io.nxmatic.nix-darwin-home.darwin.dnsmasq";
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

  system.activationScripts.postActivation.text = lib.mkAfter ''
    ${dnsmasqActivationScript}
  '';
}
