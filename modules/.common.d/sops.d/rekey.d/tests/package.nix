# sops-rekey's bats suite as a flake check: a real sops and git, throwaway age keys.
{ pkgs }:
pkgs.runCommand "sops-rekey-bats"
  {
    nativeBuildInputs = with pkgs; [
      age
      bash
      bats
      coreutils
      git
      sops
      yq-go
    ];
  }
  ''
    cp -r ${./..} rekey.d && chmod -R u+w rekey.d
    cd rekey.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
