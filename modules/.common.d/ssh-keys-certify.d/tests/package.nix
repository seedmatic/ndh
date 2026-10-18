# ssh-keys-renew's bats suite as a flake check: a real sops and a throwaway age key: the operator-seat-side signer.
{ pkgs }:
pkgs.runCommand "ssh-keys-certify-bats"
  {
    # The real logger, whose ndh::logger:command:invoke the suite's stub wrapper runs its command with.
    NDH_LOGGER_SH = ../../shell.d/logger.sh;
    # The view keys.yaml's rewrite also rewrites, by the real program and filter.
    KEYS_JSON_SH = ../../keys-yaml.d/keys-json.sh;
    PUBLIC_YQ = ../../keys-yaml.d/public.yq;
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
