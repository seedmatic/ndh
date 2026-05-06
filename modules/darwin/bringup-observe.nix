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
  self,
  ...
}:
with lib;
let
  cfg = config.bringupObserve;
  profileHome = config.profile.user.home;

  resolvedOutputDir =
    if cfg.outputDir != "" then cfg.outputDir else "${profileHome}/.local/share/nix-build-observe";

  # The aggregator needs Vector ≥ 0.55 for gRPC API support (vector tap, grpcurl).
  # Pull it directly from nixpkgs-unstable so the overlay is not needed and Linux
  # agents can stay on the stable version.
  vectorPkg =
    let
      unstable = import self.inputs.nixpkgs-unstable {
        system = pkgs.stdenv.hostPlatform.system;
        config = pkgs.config;
      };
    in
    if lib.versionAtLeast (unstable.vector.version or "0.0.0") "0.55.0"
    then unstable.vector
    else pkgs.vector;

  vectorConfigLib = import "${self}/modules/.common.d/vector-config.nix" { inherit lib; };
  vectorSettings = vectorConfigLib.mkAggregatorConfig {
    apiPort = cfg.apiPort;
    httpPort = cfg.httpPort;
    outputDir = resolvedOutputDir;
  };

  vectorConfigFile = ndh.store.writeText "bringup-observe-vector-config" (
    lib.generators.toYAML { } vectorSettings
  );

  vectorConfigFileOld = ndh.store.writeText "bringup-observe-vector-config-old" ''
    api:
      enabled: true
      address: "127.0.0.1:${toString cfg.apiPort}"

    sources:
      nix_bld_http:
        type: http_server
        address: "0.0.0.0:${toString cfg.httpPort}"
        decoding:
          codec: json
      vector_logs:
        type: internal_logs
      vector_metrics:
        type: internal_metrics

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
      vector_logs_file:
        type: file
        inputs:
          - vector_logs
        path: "${resolvedOutputDir}/vector-aggregator.log"
        encoding:
          codec: text
      vector_metrics_file:
        type: file
        inputs:
          - vector_metrics
        path: "${resolvedOutputDir}/vector-aggregator-metrics.ndjson"
        encoding:
          codec: json
  '';
  nixBuildObservePackage = pkgs.writeShellScriptBin "nix-build-observe" ''
    # Bake the resolved outputDir so `nix run` picks it up even without a login shell.
    export NDH_BUILD_OBSERVE_DIR="${resolvedOutputDir}"
    export NDH_VECTOR_HTTP_PORT="${toString cfg.httpPort}"
    export NDH_VECTOR_API_PORT="${toString cfg.apiPort}"
    ${builtins.readFile ./bringup-observe.d/nix-build-observe.sh}
  '';
in
{
  config = mkIf cfg.enable {
    environment.systemPackages = [
      vectorPkg
      nixBuildObservePackage
    ];

    environment.variables = {
      NDH_VECTOR_HTTP_PORT = toString cfg.httpPort;
      NDH_VECTOR_API_PORT  = toString cfg.apiPort;
      NDH_BUILD_OBSERVE_DIR = resolvedOutputDir;
    };

    launchd.user.agents.bringup-observe-vector = {
      serviceConfig = {
        Label = "io.nxmatic.nix-darwin-home-bringup-observe-vector";
        ProgramArguments = [
          "${vectorPkg}/bin/vector"
          "--config-yaml"
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
