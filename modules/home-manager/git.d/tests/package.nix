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
    # Every script git runs from this package (the filters and textconvs all resolve to them) names its
    # interpreter in the store: /usr/bin/env is not ours, and a build sandbox refuses it.
    bad=0
    while IFS= read -r -d "" f; do
      first=$(head -c 256 "$f" | head -n 1)
      case $first in
        '#!/nix/store/'*) ;;
        '#!'*) echo "not hermetic: $f starts with $first" >&2; bad=1 ;;
      esac
    done < <(find -L ${gitSopsDiff} -type f -print0)
    [ "$bad" = 0 ]

    cp -r ${./.} tests && chmod -R u+w tests
    cd tests && HOME=$TMPDIR bats .
    touch $out
  ''
