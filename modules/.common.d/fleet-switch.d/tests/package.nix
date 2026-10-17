# fleet-switch's bats suite as a flake check: the real script against a fake GitHub and recording stubs for ndh-switch
# and nix, on the machine list ndh-switch generates from the catalog, plus a build of the package, so its shellcheck
# runs here too.
{ pkgs, catalog }:
let
  ndhSwitch = import ../../ndh-switch.d/package.nix {
    inherit pkgs catalog;
    seat = "check";
  };
  package = import ../package.nix {
    inherit pkgs ndhSwitch;
  };
in
pkgs.runCommand "fleet-switch-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gawk
      git
      gnugrep
      gnused
      yq-go
    ];
    MACHINES = ndhSwitch.machines;
  }
  ''
    test -x ${package}/bin/fleet-switch
    cp -r ${../.} fleet-switch.d && chmod -R u+w fleet-switch.d
    cd fleet-switch.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
