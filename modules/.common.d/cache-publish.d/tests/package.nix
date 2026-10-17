# cache-publish's bats suite as a flake check: the publishable set, revisions only, the push and its check.
{ pkgs }:
pkgs.runCommand "cache-publish-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      findutils
      gawk
      gnugrep
      gnused
      yq-go
    ];
  }
  ''
    cp -r ${../.} cache-publish.d && chmod -R u+w cache-publish.d
    cd cache-publish.d/tests && bats .
    touch $out
  ''
