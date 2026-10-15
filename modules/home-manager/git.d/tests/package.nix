# The sops filters' bats suite as a flake check, against the real package home-manager installs.
{ pkgs }:
let
  gitSopsDiff = pkgs.callPackage ../git-sops-diff.nix { };
in
pkgs.runCommand "git-sops-filters-bats"
  {
    nativeBuildInputs = with pkgs; [
      age
      bats
      bash
      coreutils
      diffutils
      git
      gnugrep
      sops
      yq-go
    ];
    GIT_SOPS = gitSopsDiff;
  }
  ''
    cp -r ${./.} tests && chmod -R u+w tests
    cd tests && HOME=$TMPDIR bats .
    touch $out
  ''
