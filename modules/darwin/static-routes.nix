# Declarative static route management for macOS hosts (@codebase)
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
with lib;
let
  cfg = config.networking.staticRoutes;
  routeEnsureCommands = concatMapStringsSep "\n" (
    route:
    let
      kind = route.kind;
      destination = escapeShellArg route.destination;
      gateway = escapeShellArg route.gateway;
      ifscope = escapeShellArg (route.interface or "");
    in
    "ensure_route ${escapeShellArg kind} ${destination} ${gateway} ${ifscope}"
  ) cfg.routes;

  ensureRoutesScript = ndh.store.installScript {
    name = "darwin-static-routes-ensure.sh";
    source = pkgs.replaceVars ./static-routes.d/ensure.sh {
      ensureRoutesCommands = routeEnsureCommands;
    };
    preferLocalBuild = true;
    allowSubstitutes = false;
    mode = "0755";
  };

in
{
  options.networking.staticRoutes = {
    enable = mkEnableOption "declarative static route management";

    routes = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            kind = mkOption {
              type = types.enum [
                "net"
                "host"
              ];
              default = "net";
              description = "Route kind: network route (`net`) or host route (`host`).";
            };

            destination = mkOption {
              type = types.str;
              example = "10.80.0.0/21";
              description = "Route destination (CIDR for `net`, single IP for `host`).";
            };

            gateway = mkOption {
              type = types.str;
              example = "192.168.1.130";
              description = "Next-hop gateway IP address.";
            };

            interface = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "en9";
              description = "Optional interface scope for the route.";
            };
          };
        }
      );
      default = [ ];
      description = "Static routes to enforce on the host.";
    };

    watchPaths = mkOption {
      type = types.listOf types.str;
      default = [
        "/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist"
        "/Library/Preferences/SystemConfiguration/preferences.plist"
      ];
      description = "Paths that trigger route reconciliation when network state changes.";
    };
  };

  config = mkIf (cfg.enable && cfg.routes != [ ]) {
    launchd.daemons.static-routes = {
      script = "${ensureRoutesScript}";
      serviceConfig = {
        Label = ndh.store.mkLaunchdLabel "static-routes";
        RunAtLoad = true;
        KeepAlive = false;
        WatchPaths = cfg.watchPaths;
        StandardOutPath = "/var/log/static-routes.log";
        StandardErrorPath = "/var/log/static-routes.log";
      };
    };

    # Apply route policy during activation so it converges immediately after switch
    system.activationScripts.networking.text = mkAfter ''
      ${ensureRoutesScript}
    '';
  };
}
