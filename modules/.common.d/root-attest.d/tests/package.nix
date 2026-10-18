# ndh-root-attest's bats suite as a flake check: a throwaway P-384 root and authority keys.
{ pkgs }:
pkgs.runCommand "root-attest-bats"
  {
    ATTEST = "${pkgs.callPackage ../package.nix { }}/bin/ndh-root-attest";
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnused
      openssh
    ];
  }
  ''
    cp -r ${./..} root-attest.d && chmod -R u+w root-attest.d
    cd root-attest.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
