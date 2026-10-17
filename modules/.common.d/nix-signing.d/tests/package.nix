# ndh-nix-signing-key's bats suite as a flake check, with the real deriver.
{ pkgs }:
pkgs.runCommand "nix-signing-place-bats"
  {
    NIX_SIGNING_DERIVE = "${
      pkgs.callPackage ../../../../packages/ndh-nix-signing-derive { }
    }/bin/ndh-nix-signing-derive";
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      diffutils
      findutils
      openssh
    ];
  }
  ''
    cp -r ${./..} nix-signing.d && chmod -R u+w nix-signing.d
    cd nix-signing.d/tests && bats --print-output-on-failure .
    touch $out
  ''
