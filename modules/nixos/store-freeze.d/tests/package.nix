# ndh-store's gestures as a flake check: every system tool stubbed, the refusal-changes-nothing rule.
{ pkgs }:
pkgs.runCommand "store-freeze-bats"
  {
    nativeBuildInputs = with pkgs; [
      bash
      bats
      coreutils
      findutils
      gnugrep
      gnused
      jq
      util-linux
    ];
  }
  ''
    cp -r ${./..} store-freeze.d && chmod -R u+w store-freeze.d
    cd store-freeze.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
