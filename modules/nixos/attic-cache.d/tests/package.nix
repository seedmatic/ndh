# The cache container's bats suites as a flake check: attic-token-mint (the declared validity, the scopes, who gets a write token, the hashed
# directories), attic-cache-ensure (the key generated inside and named as the catalog accepts it), and the guest's attic-publish (the
# container's public, read as hostile input, signed by the key the guest serves) through the real trampoline and
# logger (handed over: the sandbox cannot search the store for it).
{ pkgs, trampoline }:
pkgs.runCommand "attic-cache-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      findutils
      gnugrep
      gnused
      hostname
      jq
      openssh
      openssl
      # cache-ensure builds its requests with yq, as the unit's runtimeInputs give it
      yq-go
    ];
    NDH_TRAMPOLINE = trampoline;
    NDH_BOOTSTRAP_PROFILE_DIR = import ../../../.common.d/shell.d/tests/bootstrap-profile.nix {
      inherit pkgs;
    };
  }
  ''
    cp -r ${../.} attic-cache.d && chmod -R u+w attic-cache.d
    cd attic-cache.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
