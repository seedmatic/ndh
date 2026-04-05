{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.disable-spotlight;

  disableSpotlightScript =
    pkgs.runCommand "disable-spotlight"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        install -Dm755 ${./disable-spotlight.d/disable-spotlight.sh} "$out/bin/disable-spotlight"
      '';

  disableSpotlightActivationScript = pkgs.runCommand "disable-spotlight-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./disable-spotlight.d/post-activation.sh {
        disableSpotlightScript = disableSpotlightScript;
        logger = lib.attrByPath [
          "activation"
          "loggerScript"
        ] ../common/shell.d/logger.sh config;
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
