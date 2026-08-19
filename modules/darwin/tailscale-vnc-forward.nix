{
  config,
  lib,
  pkgs,
  catalog,
  ndh,
  ...
}:

let
  tailnetDomain = catalog.netplan.tailnet.domain;
  bioskopHost = "bioskop${tailnetDomain}";
  loggerTag = "tailscale-vnc-forward";

  vncForwardScript = ndh.store.installScript {
    name = "tailscale-vnc-forward.sh";
    source = pkgs.replaceVars ./tailscale-vnc-forward.d/vnc-forward.sh {
      nixBashTrampoline = ndh.context.nixBashTrampoline;
      loggerTag = loggerTag;
      bioskopHost = bioskopHost;
      tailscale = lib.getExe pkgs.tailscale;
      jq = lib.getExe pkgs.jq;
      ssh = lib.getExe pkgs.openssh;
    };
    preferLocalBuild = true;
    allowSubstitutes = false;
    mode = "0755";
  };

in
{
  config = lib.mkIf (config.profile.host.hostName == "nikopol") {
    # LaunchAgent that reacts to network state changes (event-driven, not polling)
    launchd.user.agents.tailscale-vnc-forward = {
      serviceConfig = {
        Label = "io.seedmatic.ndh-tailscale-vnc-forward";
        ProgramArguments = [ "${vncForwardScript}" ];

        # Event-driven: react to SystemConfiguration network state changes
        # This triggers when any network interface state changes (VPN connect/disconnect, etc.)
        LaunchEvents = {
          "com.apple.SystemConfiguration.network-change" = { };
        };

        # Also run on load (at login)
        RunAtLoad = true;

        # Throttle to avoid rapid retries on network flapping
        ThrottleInterval = 5;

        # Logging
        StandardOutPath = "/tmp/tailscale-vnc-forward.log";
        StandardErrorPath = "/tmp/tailscale-vnc-forward.err";
      };
    };
  };
}
