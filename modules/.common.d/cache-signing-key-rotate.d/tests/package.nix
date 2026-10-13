# cache-signing-key-rotate's bats suite as a flake check: a real sops, a throwaway age key, `nix key`.
{ pkgs }:
pkgs.runCommand "cache-signing-key-rotate-bats"
  {
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
    cp -r ${./..} rotate && chmod -R u+w rotate
    cd rotate/tests && HOME=$TMPDIR bats .
    touch $out
  ''
