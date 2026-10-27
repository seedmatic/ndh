# viewer-kubeconfig's bats suite as a flake check: the BUILT tool (so its shellcheck runs), its PATH line stripped so a
# stub kubectl can stand in for the clusters; no network.
{ pkgs }:
let
  package = import ../package.nix { inherit pkgs; };
in
pkgs.runCommand "viewer-kubeconfig-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      gnused
      jq
    ];
  }
  ''
    grep -v '^export PATH=' ${package}/bin/viewer-kubeconfig > tool && chmod +x tool
    cp ${./viewer.bats} viewer.bats
    TOOL=$PWD/tool HOME=$TMPDIR bats viewer.bats
    touch $out
  ''
