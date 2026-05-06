# Darwin bringup observability — persistent Vector LaunchAgent for NixOS disk image builds.
#
# Options are declared in modules/.common.d/bringup-observe.nix (shared with NixOS).
# This module provides the Darwin-specific implementation:
#   - generates a static Vector config (ndh.store.writeText) routing HTTP events
#     to per-session NDJSON files via Vector path templating on {{ session }}
#   - installs a user LaunchAgent that keeps Vector running across builds
#   - exports NDH_VECTOR_* env vars so nix-build-observe.sh can locate the agent
#
# The nix-build-observe.sh script checks the Vector health endpoint; if the
# LaunchAgent is alive it posts events directly without managing lifecycle.
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
with lib;
let
  cfg = config.bringupObserve;
  profileHome = config.profile.user.home;

  resolvedOutputDir =
    if cfg.outputDir != "" then cfg.outputDir else "${profileHome}/.local/share/nix-build-observe";

  vectorConfigFile = ndh.store.writeText "bringup-observe-vector-config" ''
    api:
      enabled: true
      address: "127.0.0.1:${toString cfg.apiPort}"

    sources:
      nix_bld_http:
        type: http_server
        address: "0.0.0.0:${toString cfg.httpPort}"
        decoding:
          codec: json

    sinks:
      ndjson_file:
        type: file
        inputs:
          - nix_bld_http
        path: "${resolvedOutputDir}/{{ session }}.ndjson"
        encoding:
          codec: json
        buffer:
          type: memory
          max_events: 1
          when_full: block
  '';
in
{
  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.vector ];

    environment.variables = {
      NDH_VECTOR_HTTP_PORT = toString cfg.httpPort;
      NDH_VECTOR_API_PORT  = toString cfg.apiPort;
      NDH_BUILD_OBSERVE_DIR = resolvedOutputDir;
    };

    launchd.user.agents.bringup-observe-vector = {
      serviceConfig = {
        Label = "io.nxmatic.nix-darwin-home-bringup-observe-vector";
        ProgramArguments = [
          "${pkgs.vector}/bin/vector"
          "--config"
          "${vectorConfigFile}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Background";
        LowPriorityIO = true;
        StandardOutPath = "${resolvedOutputDir}/vector.log";
        StandardErrorPath = "${resolvedOutputDir}/vector.log";
        EnvironmentVariables = {
          HOME = profileHome;
        };
      };
    };
  };
}
