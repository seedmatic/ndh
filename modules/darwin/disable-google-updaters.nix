{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:

with lib;

let
  cfg = config.services.disable-google-updaters;
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  loggerScript = config.nixBashLogger.script;
  disableGoogleUpdatersScript = ndh.store.runCommand "disable-google-updaters" { } ''
    install -Dm755 ${./disable-google-updaters.d/disable-google-updaters.sh} "$out/bin/disable-google-updaters"
  '';
  disableGoogleUpdatersActivationScript =
    ndh.store.runCommand "disable-google-updaters-post-activation.sh" { }
      ''
        cp ${
          pkgs.replaceVars ./disable-google-updaters.d/post-activation.sh {
            nixBashTrampoline = nixBashTrampoline;
            disableGoogleUpdatersScript = disableGoogleUpdatersScript;
          }
        } "$out"
        chmod +x "$out"
      '';
in
{
  options.services.disable-google-updaters = {
    enable = mkEnableOption "automatic disabling of Google update services (Keystone, Google Updater)";
  };

  config = mkIf cfg.enable {
    # Install the shared disable script into the system profile
    environment.systemPackages = [ disableGoogleUpdatersScript ];

    # Automatically disable Google update daemons on each activation (@codebase)
    system.activationScripts.postActivation.text = mkAfter ''
      ${disableGoogleUpdatersActivationScript}
    '';
  };
}
