# ndh-claude-wake's bats suite as a flake check, plus a build of the package (stub registry), so its shellcheck runs.
{ pkgs }:
let
  package = import ../package.nix {
    inherit pkgs;
    registry = "/nonexistent/owned-dirs.json";
    bundle = "com.example.Code";
    scheme = "code-test";
  };
in
pkgs.runCommand "ndh-claude-wake-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      yq-go
    ];
  }
  ''
    test -x ${package}/bin/ndh-claude-wake
    cp -r ${../.} claude-wake.d && chmod -R u+w claude-wake.d
    cd claude-wake.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
