# Shared headscale binary pin.
#
# Both the `headscale serve` daemons (modules/{darwin,nixos}/headscale-daemon.nix)
# and the `hs` admin CLI (modules/darwin/tailnet-client-tools.nix) need to run
# the same binary.  Stock nixpkgs stable ships 0.28.0, but the access model the
# fabric control plane rests on — `grants`, and the `ssh` policy rules that make
# access a grant instead of a key — only arrives in 0.29.0, so the pin is taken
# from `nixpkgs-unstable`.  Running a CLI of one minor against a daemon of
# another triggers noisy "updated version has been found" warnings and risks
# silent drift between what the CLI parses and what the daemon accepts.
#
# Pinning the derivation in one module and having every consumer read
# `config.ndh.headscalePkg` is the single source of truth.
#
# The `>= 0.29, < 0.30` band keeps a 0.30 bump from landing silently via a
# flake lock update: 0.30 moves the admin surface to `/api/v2` + OAuth clients,
# which we deliberately do not need while the clusters stay on the Tailscale
# SaaS.  Out of band we fall back to `pkgs.headscale` and *say so* — the
# previous revision left the fallback mute and trusted a runtime symptom to
# surface it, so when unstable moved past the band the fallback engaged
# unnoticed.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  unstable = import self.inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config = pkgs.config;
  };
  v = unstable.headscale.version or "0.0.0";
  withinBand = lib.versionAtLeast v "0.29.0" && !lib.versionAtLeast v "0.30.0";
  pinned =
    lib.warnIf (!withinBand)
      "ndh.headscalePkg: nixpkgs-unstable carries headscale ${v}, outside the >= 0.29, < 0.30 band — falling back to pkgs.headscale ${pkgs.headscale.version}, which predates the `grants` policy the fabric access model requires."
      (if withinBand then unstable.headscale else pkgs.headscale);
in
{
  options.ndh.headscalePkg = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = ''
      The headscale binary used by the daemon and the `hs` admin CLI
      alike.  Pinned to the 0.29.x band via `nixpkgs-unstable`, because
      `grants` and the `ssh` policy rules arrive in 0.29.0; falls back to
      `pkgs.headscale` with an eval-time warning if unstable leaves that
      band.
    '';
  };

  config.ndh.headscalePkg = pinned;
}
