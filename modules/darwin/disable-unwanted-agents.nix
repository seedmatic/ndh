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
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  loggerScript = config.nixBashLogger.script;

  disableUnwantedAgentsScript =
    ndh.store.runCommand "disable-unwanted-agents"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        install -Dm755 ${./disable-unwanted-agents.d/disable-unwanted-agents.sh} "$out/bin/disable-unwanted-agents"
      '';

  disableUnwantedAgentsActivationScript =
    ndh.store.runCommand "disable-unwanted-agents-post-activation.sh" { }
      ''
        cp ${
          pkgs.replaceVars ./disable-unwanted-agents.d/post-activation.sh {
            nixBashTrampoline = nixBashTrampoline;
            disableUnwantedAgentsScript = disableUnwantedAgentsScript;
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
