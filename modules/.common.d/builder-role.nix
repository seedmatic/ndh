{
  config,
  lib,
  pkgs,
  ...
}:
# How many builds each kind of builder runs at once, split by who sends them: its own (max-jobs) and its own
# metalspace's clients (home). A receiving daemon has no cap across its
# connections, each of which builds at max-jobs 1 (nix 2.34 build-remote.cc), so the sum of its shares is what a
# builder runs at worst: the entries that point at it (modules/darwin/host-builder.nix) take their maxJobs here.
let
  cfg = config.ndh.builderCapacity;
  kind = if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "nixos";
  system = pkgs.stdenv.hostPlatform.system;
  maxJobs = config.nix.settings.max-jobs;
  serves =
    machines: lib.any (m: lib.elem system (m.systems or [ ]) || (m.system or null) == system) machines;
  sets = config.ndh.builderSets;
  unserved = lib.attrNames (lib.filterAttrs (_: ms: !serves ms) sets);
in
{
  options.ndh = {
    builderCapacity = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.ints.unsigned);
      readOnly = true;
      default = {
        darwin.own = 4;
        nixos = {
          own = 2;
          home = 6;
        };
      };
      description = "Concurrent builds per kind of builder: its own max-jobs, and the maxJobs of the entries its own metalspace's clients (home) send it.";
    };

    builderSets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.attrs);
      default = { };
      description = "The machines lists this host can switch between (ndh-builders), by mode; empty when nix.buildMachines is the list.";
    };
  };

  config = {
    nix.settings.max-jobs = lib.mkDefault cfg.${kind}.own;
    # max-jobs = 0 sends every build to the machines list; a system with no entry there would fail every build
    # (nix 2.34 derivation-building-goal.cc: "local builds are disabled"), whichever list is active.
    assertions = [
      {
        assertion =
          maxJobs != 0 || (if sets == { } then serves config.nix.buildMachines else unserved == [ ]);
        message = "nix max-jobs = 0, but ${
          if sets == { } then
            "no buildMachines entry"
          else
            "the builders set(s) ${lib.concatStringsSep ", " unserved}"
        } build no ${system}: every ${system} build would fail";
      }
    ];
  };
}
