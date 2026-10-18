# ndh-ceremony's bats suite as a flake check: a stand-in seedmatic key, the real root-attest, throwaway dirs.
{ pkgs }:
pkgs.runCommand "root-ceremony-bats"
  {
    ATTEST = "${pkgs.callPackage ../../root-attest.d/package.nix { }}/bin/ndh-root-attest";
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gawk
      gnupg
      gnused
      openssh
      openssl
    ];
  }
  ''
    cp -r ${./..} root-ceremony.d && chmod -R u+w root-ceremony.d
    cd root-ceremony.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
