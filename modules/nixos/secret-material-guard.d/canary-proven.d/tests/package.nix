# ndh-canary-proven's bats suite as a flake check: the real script in a throwaway checkout, against a recording stub for
# nix, plus a build of the package, so its shellcheck runs here too.
{ pkgs }:
let
  package = import ../package.nix { inherit pkgs; };
in
pkgs.runCommand "canary-proven-record-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      git
      gnugrep
    ];
  }
  ''
    test -x ${package}/bin/ndh-canary-proven
    cp -r ${../.} canary-proven.d && chmod -R u+w canary-proven.d
    cd canary-proven.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
