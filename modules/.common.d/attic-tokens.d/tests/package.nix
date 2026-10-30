# The attic token delivery's bats suites as a flake check (unseal, fetch): real age and ssh-to-age, curl stubbed,
# everything made in the sandbox.
{ pkgs }:
pkgs.runCommand "attic-tokens-bats"
  {
    nativeBuildInputs = with pkgs; [
      age
      bash
      bats
      coreutils
      diffutils
      findutils
      gnugrep
      openssh
      ssh-to-age
    ];
  }
  ''
    cp -r ${./..} attic-tokens.d && chmod -R u+w attic-tokens.d
    cd attic-tokens.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
