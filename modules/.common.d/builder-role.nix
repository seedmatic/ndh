{
  config,
  lib,
  pkgs,
  ...
}:
# How many builds each kind of builder runs at once: one table for a machine's own max-jobs and for every
# buildMachines entry that sends it builds (modules/darwin/host-builder.nix), so the two cannot drift.
let
  cfg = config.ndh.builderCapacity;
  kind = if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "nixos";
  system = pkgs.stdenv.hostPlatform.system;
  maxJobs = config.nix.settings.max-jobs;
  served = lib.any (m: lib.elem system m.systems || m.system == system) config.nix.buildMachines;
in
{
  options.ndh.builderCapacity = lib.mkOption {
    type = lib.types.attrsOf lib.types.ints.positive;
    readOnly = true;
    default = {
      darwin = 4;
      nixos = 8;
    };
    description = "Concurrent builds per kind of builder: its own max-jobs, and the maxJobs of the entries that send it builds.";
  };

  config = {
    nix.settings.max-jobs = lib.mkDefault cfg.${kind};
    # max-jobs = 0 sends every build to the machines list; a system with no entry there would fail every build
    # (nix 2.34 derivation-building-goal.cc: "local builds are disabled").
    assertions = [
      {
        assertion = maxJobs != 0 || served;
        message = "nix max-jobs = 0, but no buildMachines entry builds ${system}: every ${system} build would fail";
      }
    ];
  };
}
