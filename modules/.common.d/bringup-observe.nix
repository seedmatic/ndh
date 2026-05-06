# Bringup observability — shared option declarations for Darwin and NixOS.
#
# Platform implementations:
#   Darwin  → modules/darwin/bringup-observe.nix  (home-manager launchd agent + env vars)
#   NixOS   → modules/nixos/bringup-observe.nix   (services.vector + env vars)
#
# This module only declares the options so both platforms share a single
# interface without duplication.
{
  lib,
  ...
}:
with lib;
{
  options.bringupObserve = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the build telemetry Vector agent/aggregator.

        On Darwin: installs vector and configures a home-manager launchd agent
        that runs a persistent Vector HTTP aggregator writing NDJSON files.

        On NixOS (nerd-nixos): runs a persistent Vector agent via services.vector
        that relays events from nested QEMU builds to the macOS VZ aggregator.
      '';
    };

    httpPort = mkOption {
      type = types.port;
      default = 9001;
      description = "TCP port Vector listens on for incoming JSON events.";
    };

    apiPort = mkOption {
      type = types.port;
      default = 8687;
      description = "Vector API / health-check port (GET /health).";
    };

    upstreamEndpoint = mkOption {
      type = types.str;
      default = "";
      description = ''
        On NixOS agents: HTTP endpoint of the upstream Vector aggregator.
        Empty string on Darwin (it is the aggregator — no upstream).
        Example for nerd-nixos Lima: "http://192.168.5.2:9001" (vzNAT gateway).
      '';
    };

    outputDir = mkOption {
      type = types.str;
      default = "";
      description = ''
        Directory where the Vector aggregator writes NDJSON observation files.
        Each build session gets its own file named ``<session>.ndjson`` via
        Vector path templating on the ``session`` event field.
        Empty string means the default ``~/.local/share/nix-build-observe`` is used
        (resolved at module evaluation time from `profile.user.home` on Darwin).
      '';
    };
  };
}
