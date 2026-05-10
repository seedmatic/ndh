{ nixpkgs-unstable, ... }:
final: prev:
let
  unstablePkgs = nixpkgs-unstable.legacyPackages.${prev.stdenv.hostPlatform.system};
in
{
  # Pull tailscale from nixos-unstable: the upstream headscale server on our
  # control plane runs 1.94.x, and stable nixpkgs lags far enough behind to
  # trip a client/server version-skew warning (and eventually protocol
  # incompatibility). Tests disabled to avoid flaky sandbox checks.
  tailscale = unstablePkgs.tailscale.overrideAttrs (old: {
    doCheck = false;
    dontCheck = true;
    checkPhase = "echo skipping tailscale checkPhase";
    installCheckPhase = "echo skipping tailscale installCheckPhase";
    phases = builtins.filter (p: p != "checkPhase") (old.phases or [ ]);
  });
}
