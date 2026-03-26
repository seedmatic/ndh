{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.disable-unwanted-agents;

  disableUnwantedAgentsScript =
    pkgs.runCommand "disable-unwanted-agents"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        install -Dm755 ${./disable-unwanted-agents.d/disable-unwanted-agents.sh} "$out/bin/disable-unwanted-agents"
      '';

  disableUnwantedAgentsActivationScript =
    pkgs.runCommand "disable-unwanted-agents-post-activation.sh" { }
      ''
        cp ${
          pkgs.replaceVars ./disable-unwanted-agents.d/post-activation.sh {
            disableUnwantedAgentsScript = disableUnwantedAgentsScript;
            activationLogger = lib.attrByPath [
              "activation"
              "loggerScript"
            ] ../common/activation-logger.sh config;
          }
        } "$out"
        chmod +x "$out"
      '';
in
{
  options.services.disable-unwanted-agents = {
    enable = mkEnableOption "automatic disablement of optional third-party background agents";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ disableUnwantedAgentsScript ];

    system.activationScripts.postActivation.text = mkAfter ''
      ${disableUnwantedAgentsActivationScript}
    '';
  };
}