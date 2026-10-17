# ndh-keyring: the machines' host keys and the NixOS guests' sshfs keys in the operator's keyring (the
# seedmatic/ part of their pass store), on the operator seat holding it. The machines and guests it knows and
# the recipient it requires are fixed at evaluation.
{
  pkgs,
  lib,
  netplan,
}:
let
  hosts = lib.attrNames netplan.baremetal;
  # Each operator seat's NixOS guest, and the four machines: each operator seat and its guest, named as the
  # inventory names them.
  guests = map (h: netplan.baremetal.${h}.nixosHostname) hosts;
  machines = hosts ++ guests;
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
    guests=(${lib.concatMapStringsSep " " lib.escapeShellArg guests})
    # The seedmatic encryption subkey: the only recipient of seedmatic/.
    recipient=08C86550EBC4589C
    generate=${generate}
  ''
  + builtins.readFile ./ndh-keyring.sh;
}
