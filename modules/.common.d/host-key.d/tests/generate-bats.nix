# ndh-host-key-generate's bats suite as a flake check, on throwaway keys.
{ pkgs }:
pkgs.runCommand "host-key-generate-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      findutils
      gnugrep
      openssh
    ];
  }
  ''
    cp -r ${./..} host-key.d && chmod -R u+w host-key.d
    cd host-key.d/tests && bats --print-output-on-failure generate.bats
    touch $out
  ''
