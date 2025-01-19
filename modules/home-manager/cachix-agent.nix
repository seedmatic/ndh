{ config, pkgs, lib, ... }:

with lib;

let

  cfg = config.services.cachix-agent;
  logPrefix = "${config.home.homeDirectory}/Library/Logs/cachix-agent";

in {
  options = {
    services.cachix-agent = {

      enableLaunchdAgent = mkOption {
        type = types.bool;
        default = false;
        description = "Enable the Cachix Deploy Agent as a launchd agent.";
      };

    };
  };

  config = mkIf cfg.enableLaunchdAgent {
    assertions = [{
      assertion = pkgs.stdenv.isDarwin;
      message = "The cachix-agent service is only supported on Darwin.";
    }];

    launchd.agents.cachix-agent = mkIf cfg.enableLaunchdAgent {
      enable = true;
      config = {
        Label = "org.nix-community.home.cachix-agent";
        ProgramArguments = [
          "${pkgs.bash}/bin/bash"
          "-c"
          ''
            export CACHIX_AGENT_TOKEN="$(cat ${cfg.credentialsFile})"
            exec ${cfg.package}/bin/cachix deploy agent ${cfg.name} ${
              optionalString cfg.verbose "--verbose"
            } ${
              optionalString (cfg.host != null) "--host ${cfg.host}"
            } ${
              optionalString (cfg.profile != null) cfg.profile
            }
          ''
        ];
        EnvironmentVariables = {
          PATH = "${if config.nix.enable && config.nix.package != null then config.nix.package else pkgs.nix}/bin";
        };
        RunAtLoad = true;
        KeepAlive = true;
        StandardErrorPath = "${logPrefix}.err";
        StandardOutPath = "${logPrefix}.out";
      };
    };

    xdg.configFile."cachix/cachix.dhall" = {
      source = ./cachix-agent.dhall;
    };
  };
}