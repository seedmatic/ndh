# sops-rekey (see rekey.sh): the operator's re-seal of this repository's sops files after a .sops.yaml change.
{ pkgs }:
pkgs.writeShellApplication {
  name = "sops-rekey";
  runtimeInputs = with pkgs; [
    coreutils
    git
    sops
    yq-go
  ];
  text = builtins.readFile ./rekey.sh;
}
