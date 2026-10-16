# attic-tls-key's bats suite as a flake check: the key is never replaced, a foreign leaf is refused.
{ pkgs }:
pkgs.runCommand "attic-tls-key-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      openssl
    ];
  }
  ''
    cp -r ${../.} attic-cache.d && chmod -R u+w attic-cache.d
    cd attic-cache.d/tests && bats .
    touch $out
  ''
