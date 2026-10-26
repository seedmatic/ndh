# corp-egress-anchor's bats suite as a flake check: pfctl stood in for, placeholder addresses only.
{ pkgs }:
pkgs.runCommand "corp-egress-anchor-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gawk
      gnugrep
      gnused
      diffutils
    ];
  }
  ''
    cp -r ${./..} corp-egress-guard && chmod -R u+w corp-egress-guard
    cd corp-egress-guard/tests && HOME=$TMPDIR bats --print-output-on-failure anchor.bats
    touch $out
  ''
