# Shared Vector configuration generator for bringup observability.
#
# Provides a single source of truth for Vector config structure used across:
#   - Darwin LaunchAgent (bringup-observe.nix)
#   - linux-builder Vector agent
#   - NixOS VM Vector agents
#
# Returns a function that generates Vector settings attrset from parameters.
{ lib }:
{
  # Generate Vector aggregator config (Darwin host, collects and persists to NDJSON).
  #
  # Sentinel gate: the `require_session` filter drops any event lacking a
  # `.session` field. That prevents stray posts (or future internal probes) from
  # landing in an unscoped output file — every sample must declare its session.
  mkAggregatorConfig =
    {
      apiPort,
      httpPort,
      outputDir,
    }:
    {
      api = {
        enabled = true;
        address = "127.0.0.1:${toString apiPort}";
      };

      sources.nix_bld_http = {
        type = "http_server";
        address = "0.0.0.0:${toString httpPort}";
        decoding.codec = "json";
      };

      transforms.require_session = {
        type = "filter";
        inputs = [ "nix_bld_http" ];
        condition = ''exists(.session) && .session != ""'';
      };

      sinks.ndjson_file = {
        type = "file";
        inputs = [ "require_session" ];
        path = "${outputDir}/{{ session }}.ndjson";
        encoding.codec = "json";
        buffer = {
          type = "memory";
          max_events = 1;
          when_full = "block";
        };
      };
    };

  # Generate Vector agent config (NixOS VMs, forwards to upstream).
  #
  # Same sentinel gate as the aggregator: unsessioned posts are dropped before
  # they travel up the relay chain to the macOS aggregator.
  mkAgentConfig =
    {
      apiPort,
      httpPort,
      upstreamEndpoint,
    }:
    {
      api = {
        enabled = true;
        address = "127.0.0.1:${toString apiPort}";
      };

      sources.nix_bld_http = {
        type = "http_server";
        address = "0.0.0.0:${toString httpPort}";
        decoding.codec = "json";
      };

      transforms.require_session = {
        type = "filter";
        inputs = [ "nix_bld_http" ];
        condition = ''exists(.session) && .session != ""'';
      };

      sinks.forward_to_vz = {
        type = "http";
        inputs = [ "require_session" ];
        uri = upstreamEndpoint;
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
}
