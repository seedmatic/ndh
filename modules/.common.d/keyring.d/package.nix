# ndh-keyring: the machines' host keys in the operator's keyring (the seedmatic/ part of their pass store),
# on the seat holding it. The machines it knows and the recipient it requires are fixed at evaluation.
{
  pkgs,
  lib,
  netplan,
}:
let
  hosts = lib.attrNames netplan.baremetal;
  # The four machines: each seat and its guest, named as the inventory names them.
  machines = hosts ++ map (h: netplan.baremetal.${h}.nixosHostname) hosts;
  python = pkgs.python3.withPackages (ps: [ ps.cryptography ]);
  generate = pkgs.writeShellScript "ndh-keyring-gen-ed25519" ''
    exec ${python}/bin/python3 -I ${./gen-ed25519.py}
  '';
in
pkgs.writeShellApplication {
  name = "ndh-keyring";
  runtimeInputs = [
    pkgs.age
    pkgs.coreutils
    pkgs.gawk
    pkgs.gnupg
    pkgs.gnused
    pkgs.openssh
    pkgs.pass
    pkgs.ssh-to-age
  ];
  text = ''
    machines=(${lib.concatMapStringsSep " " lib.escapeShellArg machines})
    # The seedmatic encryption subkey: the only recipient of seedmatic/.
    recipient=08C86550EBC4589C
    generate=${generate}
  ''
  + builtins.readFile ./ndh-keyring.sh;
}
