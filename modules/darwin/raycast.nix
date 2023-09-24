{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.raycast;
in {
  options = {
    services.raycast = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to enable the Raycast service.";
      };

      homeDir = mkOption {
        type = types.nullOr types.path;
        default = "~";
        example = "/Users/nxmatic";
        description = ''
          the base location for the raycast folder
        '';
      };

      logDir = mkOption {
        type = types.nullOr types.path;
        default = "~/Library/Logs";
        example = "~/Library/Logs";
        description = ''
          The logfile to use for the Syncthing service.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [pkgs.raycast];
    launchd.user.agents.raycast = {
      command = "${lib.getExe pkgs.raycast}";
      serviceConfig = {
        Label = "net.raycast.raycast";
        KeepAlive = true;
        LowPriorityIO = true;
        ProcessType = "Background";
        StandardOutPath = "${cfg.logDir}/Raycast.log";
        StandardErrorPath = "${cfg.logDir}/Raycast-Errors.log";
        EnvironmentVariables = {
          NIX_PATH = "nixpkgs=" + toString pkgs.path;
          STNORESTART = "1";
        };
      };
    };
  };
}
