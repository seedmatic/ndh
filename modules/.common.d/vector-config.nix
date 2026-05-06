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
  # Generate Vector aggregator config (Darwin host, collects and persists to NDJSON)
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

      sources = {
        nix_bld_http = {
          type = "http_server";
          address = "0.0.0.0:${toString httpPort}";
          decoding.codec = "json";
        };
        vector_logs = {
          type = "internal_logs";
        };
        vector_metrics = {
          type = "internal_metrics";
        };
      };

      sinks = {
        ndjson_file = {
          type = "file";
          inputs = [ "nix_bld_http" ];
          path = "${outputDir}/{{ session }}.ndjson";
          encoding.codec = "json";
          buffer = {
            type = "memory";
            max_events = 1;
            when_full = "block";
          };
        };
        vector_logs_file = {
          type = "file";
          inputs = [ "vector_logs" ];
          path = "${outputDir}/vector-aggregator.log";
          encoding.codec = "text";
        };
        vector_metrics_file = {
          type = "file";
          inputs = [ "vector_metrics" ];
          path = "${outputDir}/vector-aggregator-metrics.ndjson";
          encoding.codec = "json";
        };
      };
    };

  # Generate Vector agent config (NixOS VMs, forwards to upstream)
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

      sources = {
        nix_bld_http = {
          type = "http_server";
          address = "0.0.0.0:${toString httpPort}";
          decoding.codec = "json";
        };
        vector_logs = {
          type = "internal_logs";
        };
        vector_metrics = {
          type = "internal_metrics";
        };
      };

      sinks = {
        forward_to_vz = {
          type = "http";
          inputs = [ "nix_bld_http" ];
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
        vector_logs_stderr = {
          type = "console";
          inputs = [ "vector_logs" ];
          target = "stderr";
          encoding.codec = "text";
        };
        vector_metrics_stderr = {
          type = "console";
          inputs = [ "vector_metrics" ];
          target = "stderr";
          encoding.codec = "json";
        };
      };
    };
}
