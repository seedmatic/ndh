{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:

with lib;

let
  cfg = config.services.disable-spotlight;
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  loggerScript = config.nixBashLogger.script;

  disableSpotlightScript =
    ndh.store.runCommand "disable-spotlight"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        install -Dm755 ${./disable-spotlight.d/disable-spotlight.sh} "$out/bin/disable-spotlight"
      '';

  disableSpotlightActivationScript =
    ndh.store.runCommand "disable-spotlight-post-activation.sh" { }
      ''
        cp ${
          pkgs.replaceVars ./disable-spotlight.d/post-activation.sh {
            nixBashTrampoline = nixBashTrampoline;
            disableSpotlightScript = disableSpotlightScript;
          }
        } "$out"
        chmod +x "$out"
      '';
in
{
  options.services.disable-spotlight = {
    enable = mkEnableOption "automatic Spotlight indexing disablement and index cleanup on mounted volumes";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ disableSpotlightScript ];

    system.activationScripts.postActivation.text = mkAfter ''
      ${disableSpotlightActivationScript}
    '';
  };
}
