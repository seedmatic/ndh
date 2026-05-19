# NixOS bringup observability — Vector agent for build telemetry forwarding.
#
# Options are declared in modules/.common.d/bringup-observe.nix (shared with Darwin).
# This module provides the NixOS-specific implementation via services.vector:
#   - listens for JSON events from nested QEMU (via SLIRP 10.0.2.2:httpPort)
#   - forwards all events to the macOS VZ aggregator (upstreamEndpoint)
#
# nixpkgs validates the Vector config at build time before activating.
{
  config,
  lib,
  paths,
  ...
}:
with lib;
let
  cfg = config.bringupObserve;
in
{
  config = mkIf cfg.enable (
    let
      vectorConfigLib = import paths.modulesCommonVectorConfig { inherit lib; };
    in
    {
      services.vector = {
        enable = true;
        settings = vectorConfigLib.mkAgentConfig {
          apiPort = cfg.apiPort;
          httpPort = cfg.httpPort;
          upstreamEndpoint = cfg.upstreamEndpoint;
        };
      };

      environment.variables = {
        NDH_VECTOR_HTTP_PORT = toString cfg.httpPort;
        NDH_VECTOR_API_PORT = toString cfg.apiPort;
        NDH_VECTOR_ENDPOINT = "http://127.0.0.1:${toString cfg.httpPort}";
      };
    }
  );
}
