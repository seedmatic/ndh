{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.ndh.cometDebug;

  cometApp = "/Volumes/user-home/Applications/Comet.app";
in
{
  options = {
    ndh.cometDebug = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable Comet browser with Chrome DevTools remote debugging.";
      };

      debugPort = mkOption {
        type = types.int;
        default = 9222;
        description = "Port for Chrome DevTools Protocol remote debugging.";
      };

      cometPath = mkOption {
        type = types.str;
        default = cometApp;
        description = "Path to Comet.app";
      };
    };
  };

  config = mkIf cfg.enable {
    launchd.agents.comet-debug = {
      enable = true;
      config = {
        Label = "io.nxmatic.nix-darwin-home.comet-debug";
        ProgramArguments = [
          "/usr/bin/open"
          "-a"
          cfg.cometPath
          "--args"
          "--remote-debugging-port=${toString cfg.debugPort}"
        ];
        RunAtLoad = true;
        KeepAlive = {
          SuccessfulExit = false;
          Crashed = true;
        };
        ProcessType = "Interactive";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/comet-debug.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/comet-debug.log";
        EnvironmentVariables = {
          PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
        };
      };
    };

    # Helper script to check debug port status
    home.packages = [
      (pkgs.writeShellScriptBin "comet-debug-status" ''
        PORT=${toString cfg.debugPort}
        if curl -s "http://localhost:$PORT/json/version" > /dev/null 2>&1; then
          echo "✓ Comet debug interface available at http://localhost:$PORT"
          ${pkgs.curl}/bin/curl -s "http://localhost:$PORT/json/version" | ${pkgs.jq}/bin/jq .
        else
          echo "⚠ Comet debug port $PORT not responding"
          exit 1
        fi
      '')
    ];

    home.activation.cometDebugInfo = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $VERBOSE_ECHO "Comet debug agent configured on port ${toString cfg.debugPort}"
      $VERBOSE_ECHO "Check status with: comet-debug-status"
      $VERBOSE_ECHO "Load/unload with: launchctl {load,unload} ~/Library/LaunchAgents/io.nxmatic.nix-darwin-home.comet-debug.plist"
    '';
  };
}
