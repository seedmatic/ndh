# The cache container's bats suites as a flake check: attic-tls-key (the key is never replaced, a
# foreign leaf is refused), attic-token-issue (one far validity, the scopes, who gets a write token) and
# attic-cache-ensure (the key generated inside and named as the catalog accepts it).
{ pkgs }:
pkgs.runCommand "attic-cache-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      findutils
      gnugrep
      gnused
      jq
      openssl
    ];
  }
  ''
    cp -r ${../.} attic-cache.d && chmod -R u+w attic-cache.d
    cd attic-cache.d/tests && bats .
    touch $out
  ''
