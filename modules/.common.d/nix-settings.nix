# Shared baseline nix.settings for NixOS and nix-darwin.
#
# Single source of truth for the experimental-features list every NDH
# system needs: `nix-command` + `flakes` at minimum, plus `ca-derivations`
# (content-addressed derivations reduce rebuild churn across hosts) and
# `configurable-impure-env` (allows --impure-env used by the nix-build-observe
# wrapper). Both NixOS and nix-darwin expose `nix.settings.experimental-features`
# as a list option via their platform modules; `lib.mkDefault` lets any
# consumer tighten or extend the set without conflict.
{ lib, ... }:
{
  nix.settings.experimental-features = lib.mkDefault [
    "nix-command"
    "flakes"
    "ca-derivations"
    "configurable-impure-env"
  ];
}
