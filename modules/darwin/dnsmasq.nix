{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  user = config.profile.user;
  userName = user.name;
  logFile = "/Users/${userName}/Library/Logs/dnsmasq.log";

  dnsmasqActivationScript = ndh.store.runCommand "dnsmasq-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./dnsmasq.d/post-activation.sh {
        nixBashTrampoline = nixBashTrampoline;
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
