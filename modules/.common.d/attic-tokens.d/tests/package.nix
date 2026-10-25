# The attic token delivery's bats suites as a flake check (unseal, fetch): real age and ssh-to-age, curl stubbed but for the TLS cases (a real local server),
# everything made in the sandbox.
{ pkgs }:
pkgs.runCommand "attic-tokens-bats"
  {
    # The TLS cases run a real server on loopback: darwin's sandbox refuses a listening socket unless asked.
    __darwinAllowLocalNetworking = true;
    nativeBuildInputs = with pkgs; [
      age
      bash
      bats
      coreutils
      diffutils
      findutils
      gnugrep
      curl
      openssh
      openssl
      ssh-to-age
    ];
  }
  ''
    cp -r ${./..} attic-tokens.d && chmod -R u+w attic-tokens.d
    cd attic-tokens.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
