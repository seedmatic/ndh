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
  ...
}:
with lib;
let
  cfg = config.bringupObserve;
in
{
  config = mkIf cfg.enable {
    services.vector = {
      enable = true;
      settings = {
        api = {
          enabled = true;
          address = "127.0.0.1:${toString cfg.apiPort}";
        };

        sources.nix_bld_http = {
          type = "http_server";
          address = "0.0.0.0:${toString cfg.httpPort}";
          decoding.codec = "json";
        };

        sinks.forward_to_vz = {
          type = "http";
          inputs = [ "nix_bld_http" ];
          uri = cfg.upstreamEndpoint;
          method = "post";
          encoding.codec = "json";
          request.headers."Content-Type" = "application/json";
          buffer = {
            type = "memory";
            max_events = 1;
            when_full = "block";
          };
        };
      };
    };

    environment.variables = {
      NDH_VECTOR_HTTP_PORT = toString cfg.httpPort;
      NDH_VECTOR_API_PORT  = toString cfg.apiPort;
      NDH_VECTOR_ENDPOINT  = "http://127.0.0.1:${toString cfg.httpPort}";
    };
  };
}
