# cache-signing-key-rotate's bats suite as a flake check: a real sops, a throwaway age key, `nix key`,
# and the whole .common.d tree, because one case runs the tool under the real logger wrapper.
{ pkgs }:
pkgs.runCommand "cache-signing-key-rotate-bats"
  {
    # The real logger, whose ndh::logger:command:invoke the suite's stub wrapper runs its command with.
    NDH_LOGGER_SH = ../../shell.d/logger.sh;
    nativeBuildInputs = with pkgs; [
      age
      bats
      bash
      coreutils
      git
      gnugrep
      gnused
      nix
      sops
      yq-go
    ];
  }
  ''
    cp -r ${../..} common && chmod -R u+w common
    cd common/cache-signing-key-rotate.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
