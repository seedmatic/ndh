# ndh-builders' bats suite as a flake check.
{ pkgs }:
pkgs.runCommand "ndh-builders-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
    ];
  }
  ''
    cp -r ${./..} host-builder.d && chmod -R u+w host-builder.d
    cd host-builder.d/tests && bats --print-output-on-failure .
    touch $out
  ''
