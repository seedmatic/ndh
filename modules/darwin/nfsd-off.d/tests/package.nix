# nfsd-off's bats suite as a flake check: nfsd stood in for, the exports file in a temporary /etc.
{ pkgs }:
pkgs.runCommand "nfsd-off-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
    ];
  }
  ''
    cp -r ${./..} nfsd-off && chmod -R u+w nfsd-off
    cd nfsd-off/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
