{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:

with lib;

let
  cfg = config.services.disable-unwanted-agents;
  loggerScript = config.nixBashLogger.script;

  disableUnwantedAgentsScript =
    pkgs.runCommand (ndh.store.prefixedName "disable-unwanted-agents")
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        install -Dm755 ${./disable-unwanted-agents.d/disable-unwanted-agents.sh} "$out/bin/disable-unwanted-agents"
      '';

  disableUnwantedAgentsActivationScript =
    pkgs.runCommand (ndh.store.prefixedName "disable-unwanted-agents-post-activation.sh") { }
      ''
        cp ${
          pkgs.replaceVars ./disable-unwanted-agents.d/post-activation.sh {
            disableUnwantedAgentsScript = disableUnwantedAgentsScript;
            logger = loggerScript;
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
