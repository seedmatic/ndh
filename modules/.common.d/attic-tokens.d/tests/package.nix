# ndh-attic-tokens-unseal's bats suite as a flake check: real age and ssh-to-age, everything made in the sandbox.
{ pkgs }:
pkgs.runCommand "attic-tokens-unseal-bats"
  {
    nativeBuildInputs = with pkgs; [
      age
      bash
      bats
      coreutils
      findutils
      openssh
      ssh-to-age
    ];
  }
  ''
    cp -r ${./..} attic-tokens.d && chmod -R u+w attic-tokens.d
    cd attic-tokens.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
