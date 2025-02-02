{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.shadowRepositories;
  script = pkgs.writeScriptBin "mount-shadow-repositories.sh"
    (builtins.readFile ./shadow-repositories.sh);
in {
  options = {
    services.shadowRepositories = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable the shadow-repositories service.";
      };

      mountPoints = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "List of mount points for the shadowed repositories.";
      };

      scriptPath = mkOption {
        type = types.str;
        default = "${script}/bin/mount-shadow-repositories.sh";
        description = "Path to the mount-shadow-repositories script.";
      };
    };
  };

  config = mkIf cfg.enable {
    launchd.agents.shadow-repositories = {
      enable = true;
      config = {
        Label = "org.nix-community.home.shadow-repositories";
        ProgramArguments = [ cfg.scriptPath ] ++ cfg.mountPoints;
        RunAtLoad = true;
        KeepAlive = false;
        EnvironmentVariables = {
          PATH = "/usr/sbin:${pkgs.coreutils}/bin:${pkgs.rsync}/bin:${pkgs.yq}/bin:$PATH";
        };
      };
    };
  };
}
