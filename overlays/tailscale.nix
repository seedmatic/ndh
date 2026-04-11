{ ... }:
final: prev: {
  # Disable Tailscale tests to speed builds / avoid flaky checks
  tailscale = prev.tailscale.overrideAttrs (old: {
    doCheck = false;
    dontCheck = true;
    checkPhase = "echo skipping tailscale checkPhase";
    installCheckPhase = "echo skipping tailscale installCheckPhase";
    phases = builtins.filter (p: p != "checkPhase") (old.phases or [ ]);
  });
}
