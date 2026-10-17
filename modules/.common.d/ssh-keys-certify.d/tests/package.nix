# ssh-keys-renew's bats suite as a flake check: a real sops and a throwaway age key: the operator-seat-side signer.
{ pkgs }:
pkgs.runCommand "ssh-keys-certify-bats"
  {
    # The real logger, whose ndh::logger:command:invoke the suite's stub wrapper runs its command with.
    NDH_LOGGER_SH = ../../shell.d/logger.sh;
    nativeBuildInputs = with pkgs; [
      age
      bats
      bash
      coreutils
      gawk
      git
      gnugrep
      gnused
      openssh
      sops
      yq-go
    ];
  }
  ''
    cp -r ${./..} certify && chmod -R u+w certify
    cd certify/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
