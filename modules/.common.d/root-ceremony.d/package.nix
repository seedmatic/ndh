# ndh-ceremony: the seedmatic root's ceremony, run inside the ceremony VM only (docs/root-ceremony.adoc).
{ pkgs }:
pkgs.writeShellApplication {
  name = "ndh-ceremony";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gawk
    pkgs.gnupg
    pkgs.gnused
    pkgs.openssh
    pkgs.openssl
  ];
  text = ''
    in=/ceremony/in
    out=/ceremony/out
    work=/run/ceremony
    passphraseFrom=/dev/console
    attest=${pkgs.callPackage ../root-attest.d/package.nix { }}/bin/ndh-root-attest
    recipient=${import ../keyring.d/seedmatic-recipient.nix}
  ''
  + builtins.readFile ./ndh-ceremony.sh;
}
