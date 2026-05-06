# Vector overlay — pin to 0.55.0+ for gRPC API support.
#
# Vector 0.55.0 includes gRPC reflection for the observability API, required by
# `grpcurl` and `vector tap` for real-time event streaming. The 0.52.0 version
# in stable nixpkgs lacks this feature.
#
# This overlay pulls Vector from nixos-unstable when the stable version < 0.55.0.
inputs: final: prev:
let
  inherit (prev.lib) versionAtLeast;
  currentVersion = prev.vector.version or "0.0.0";
  minVersion = "0.55.0";
  needsUpgrade = !(versionAtLeast currentVersion minVersion);
in
{
  vector = if needsUpgrade then
    (import inputs.nixpkgs-unstable {
      system = prev.stdenv.hostPlatform.system;
      config = prev.config;
    }).vector
  else
    prev.vector;
}
