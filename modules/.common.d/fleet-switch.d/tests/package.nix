# fleet-switch's bats suite as a flake check: the real script against a fake GitHub and recording stubs for ndh-switch
# and nix, plus a build of the package, so its shellcheck runs here too.
{ pkgs }:
let
  package = import ../package.nix {
    inherit pkgs;
    ndhSwitch = pkgs.writeShellScriptBin "ndh-switch" "exit 99";
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
  }
  ''
    test -x ${package}/bin/fleet-switch
    mkdir -p .common.d && cp -r ${../.} .common.d/fleet-switch.d && cp -r ${../../ndh-switch.d} .common.d/ndh-switch.d
    chmod -R u+w .common.d
    cd .common.d/fleet-switch.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
