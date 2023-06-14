{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.tailscale;
in {
  config = mkIf cfg.enable {
    environment.systemPackages = [pkgs.tailscale];
    launchd.user.agents.tailscale = {
      command = "${lib.getExe pkgs.tailscale}";
      serviceConfig = {
        Label = "net.tailscale.tailscale";
        KeepAlive = true;
        LowPriorityIO = true;
        ProcessType = "Background";
#        StandardOutPath = "~/Library/Logs/Tailscale.log";
#        StandardErrorPath = builtins.unsafeDiscardStringContext (toString "~/Library/Logs/Tailscale-Errors.log");
        EnvironmentVariables = {
          NIX_PATH = "nixpkgs=" + toString pkgs.path;
          STNORESTART = "1";
        };
      };
    };
  };
}
