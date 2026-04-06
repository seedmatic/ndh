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
  loggerScript = config.nixBashLogger.script;

  disableSpotlightScript =
    pkgs.runCommand (ndh.store.prefixedName "disable-spotlight")
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        install -Dm755 ${./disable-spotlight.d/disable-spotlight.sh} "$out/bin/disable-spotlight"
      '';

  disableSpotlightActivationScript = pkgs.runCommand (ndh.store.prefixedName "disable-spotlight-post-activation.sh") { } ''
    cp ${
      pkgs.replaceVars ./disable-spotlight.d/post-activation.sh {
        disableSpotlightScript = disableSpotlightScript;
        logger = loggerScript;
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
