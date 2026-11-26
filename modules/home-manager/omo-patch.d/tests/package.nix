{ pkgs, omoPatch }:
pkgs.runCommand "omo-patch-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      coreutils
      gnugrep
      yq-go
      mdpatch
    ];
  }
  ''
    cp -r ${./.} tests && chmod -R u+w tests
    (cd tests && HOME=$TMPDIR PATH=${omoPatch}/bin:$PATH bats --print-output-on-failure .)
    touch $out
  ''
