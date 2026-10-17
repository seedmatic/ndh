# attic-leaf-sign's bats suite as a flake check: the real path, through to the served leaf.
{ pkgs }:
pkgs.runCommand "attic-leaf-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      gnused
      openssl
      step-cli
      yq-go
    ];
  }
  ''
    # The whole modules tree: the signer sources ../shell.d/logger.sh.
    cp -r ${../../..} modules && chmod -R u+w modules
    cd modules/.common.d/attic-leaf.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
