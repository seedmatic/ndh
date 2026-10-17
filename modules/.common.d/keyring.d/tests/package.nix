# ndh-keyring's bats suite as a flake check: the real generator, pass and gpg, a throwaway key and store.
{ pkgs }:
pkgs.runCommand "keyring-bats"
  {
    nativeBuildInputs = with pkgs; [
      age
      bats
      bash
      coreutils
      findutils
      gawk
      gnugrep
      gnupg
      gnused
      openssh
      pass
      (python3.withPackages (ps: [ ps.cryptography ]))
      ssh-to-age
    ];
  }
  ''
    cp -r ${./..} keyring.d && chmod -R u+w keyring.d
    cd keyring.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
