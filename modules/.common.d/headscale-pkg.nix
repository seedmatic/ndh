# Shared headscale binary pin.
#
# Both the `headscale serve` daemon (modules/darwin/headscale-daemon.nix)
# and the `hs` admin CLI (modules/darwin/headscale-tools.nix) need to
# run the same binary.  Stock nixpkgs stable ships 0.27.1 but the
# pre-auth-key + policy-v2 behaviour we depend on only stabilised in
# the 0.28.x line, pulled from `nixpkgs-unstable`.  Running a 0.27.1
# CLI against a 0.28 daemon triggers noisy "updated version has been
# found" warnings and risks silent behavioural drift between what
# the CLI parses and what the daemon accepts.
#
# Pinning this derivation in one module and having both consumers
# read `config.ndh.headscalePkg` is the single source of truth.
# Version is pinned to the `>= 0.28, < 0.29` band so an unstable
# bump to 0.29 (expected to carry more breaking changes) can't
# silently land via a flake lock update; the module falls back to
# `pkgs.headscale` instead, which flags the regression via the 0.27
# runtime complaining about 0.28 DB columns.  Same pattern as
# modules/darwin/bringup-observe.nix for Vector.
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
  withinBand = lib.versionAtLeast v "0.28.0" && !lib.versionAtLeast v "0.29.0";
  pinned = if withinBand then unstable.headscale else pkgs.headscale;
in
{
  options.ndh.headscalePkg = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = ''
      The headscale binary used by both the daemon (where applicable)
      and the `hs` admin CLI.  Pinned to the 0.28.x band via
      `nixpkgs-unstable`; falls back to `pkgs.headscale` if unstable
      ever regresses below 0.28 or jumps to 0.29+.
    '';
  };

  config.ndh.headscalePkg = pinned;
}
