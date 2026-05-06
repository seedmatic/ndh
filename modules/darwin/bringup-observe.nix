# Darwin bringup observability — Vector HTTP aggregator for NixOS disk image builds.
#
# Options are declared in modules/.common.d/bringup-observe.nix (shared with NixOS).
# This module provides the Darwin-specific implementation:
#   - installs vector as a system package
#   - exports NDH_VECTOR_* env vars so nix-build-observe.sh picks them up
#
# The script bin/nix-build-observe.sh manages the Vector process lifecycle
# (start/stop per build session) using a dynamic config with per-session output paths.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.bringupObserve;
in
{
  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.vector ];

    environment.variables = {
      NDH_VECTOR_HTTP_PORT = toString cfg.httpPort;
      NDH_VECTOR_API_PORT  = toString cfg.apiPort;
    };
  };
}
