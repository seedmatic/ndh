# The headscale client lib's bats suite as a flake check: the real lib.sh, a stub tailscale that records its argv.
{ pkgs }:
pkgs.runCommand "headscale-client-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
    ];
  }
  ''
    cp -r ${./..} hc && chmod -R u+w hc
    cd hc/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
