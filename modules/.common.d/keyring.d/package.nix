# ndh-keyring: the machines' host keys, the NixOS guests' sshfs keys, the foreign vz-hosts' vz-recover keys and
# the cluster's age identity in the operator's keyring (the seedmatic/ part of their pass store), on the operator
# seat holding it. The machines, guests and vz-hosts it knows and the recipient it requires are fixed at
# evaluation.
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
  # The vz-hosts that are not nix-managed, each with the authorized_keys options of its vz-recover key, in the
  # account the catalog names.
  vzHosts = lib.filter (h: netplan.baremetal.${h}.vzHostKind == "foreign") hosts;
  vzRecover = import ../../../pkgs/vz-recover.d/authorized-options.nix;
  vzRecoverOptions =
    h: vzRecover.options (vzRecover.installed "/Users/${netplan.baremetal.${h}.vzHostUser}");
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
    vzHosts=(${lib.concatMapStringsSep " " lib.escapeShellArg vzHosts})
    declare -A vzRecoverOptions=(${
      lib.concatMapStringsSep " " (h: "[${h}]=${lib.escapeShellArg (vzRecoverOptions h)}") vzHosts
    })
    recipient=${import ./seedmatic-recipient.nix}
    generate=${generate}
    derive=${pkgs.callPackage ../../../packages/ndh-nix-signing-derive { }}/bin/ndh-nix-signing-derive
    # The label's version, so the key name's: seedmatic/nix-signing/<n> gives seedmatic-<machine>-<n>.
    nixSigningVersion=1
  ''
  + builtins.readFile ./ndh-keyring.sh;
}
