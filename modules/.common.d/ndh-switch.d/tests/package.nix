# ndh-switch's bats suite as a flake check: the real script against a fake GitHub and recording stubs, plus a
# build of the package, so its shellcheck runs here too.
{ pkgs }:
let
  package = import ../package.nix {
    inherit pkgs;
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
      jq
    ];
  }
  ''
    test -x ${package}/bin/ndh-switch
    cp -r ${../.} ndh-switch.d && chmod -R u+w ndh-switch.d
    cd ndh-switch.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
