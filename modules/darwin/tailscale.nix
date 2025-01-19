{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  
  user = config.profile.user;
  userHome = user.home;

  cfg = config.services.tailscale;
  logPrefix = "${userHome}/Library/Logs/tailscale";
in {
  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.tailscale ];
    launchd.agents.tailscale = {
      command = "${lib.getExe pkgs.tailscale}";
      config = {
        Label = "org.nix-community.home.tailscale";
        ProgramArguments = [ "${lib.getExe pkgs.tailscale}" "up" ];
        KeepAlive = true;
        LowPriorityIO = true;
        ProcessType = "Background";
        StandardOutPath = "${logPrefix}-out.log";
        StandardErrorPath = "${logPrefix}-error.log";
        EnvironmentVariables = {
          NIX_PATH = "nixpkgs=" + toString pkgs.path;
          STNORESTART = "1";
        };
      };
    };
  };
}