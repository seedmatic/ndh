# ndh-switch's bats suite as a flake check: the real script against a fake GitHub and recording stubs, on the machine
# list the package generates from the catalog, plus a build of the package, so its shellcheck runs here too.
{ pkgs, catalog }:
let
  package = import ../package.nix {
    inherit pkgs catalog;
    seat = "check";
  };
in
pkgs.runCommand "ndh-switch-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      git
      gnugrep
      gnused
      yq-go
    ];
    MACHINES = package.machines;
  }
  ''
    test -x ${package}/bin/ndh-switch
    cp -r ${../.} ndh-switch.d && chmod -R u+w ndh-switch.d
    cd ndh-switch.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
