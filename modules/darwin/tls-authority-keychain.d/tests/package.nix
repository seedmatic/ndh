# The keychain reconciliation's bats suite as a flake check: which roots are stale.
{ pkgs, trampoline }:
pkgs.runCommand "tls-authority-keychain-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gawk
      gnugrep
      gnused
      openssl
      xxd
    ];
    NDH_TRAMPOLINE = trampoline;
    NDH_BOOTSTRAP_PROFILE_DIR = import ../../../.common.d/shell.d/tests/bootstrap-profile.nix {
      inherit pkgs;
    };
  }
  ''
    cp -r ${./..} src && chmod -R u+w src
    cd src/tests && HOME=$TMPDIR bats .
    touch $out
  ''
