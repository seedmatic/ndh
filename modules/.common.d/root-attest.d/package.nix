# ndh-root-attest: the canonical statement the seedmatic root signs for an authority, and its verification
# (docs/root-ceremony.adoc). Used inside the ceremony VM to write the statements, and by the tools that trust an
# authority only once its statement verifies.
{ pkgs }:
pkgs.writeShellApplication {
  name = "ndh-root-attest";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.diffutils
    pkgs.gnused
    pkgs.openssh
  ];
  text = builtins.readFile ./ndh-root-attest.sh;
}
