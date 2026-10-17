# The attic token delivery (roles × keys ⑤), one definition for every machine: the unseal (unseal.sh) and the
# receive (receive.sh), built for one machine, and the operator seat's deposit (deposit.sh).
{
  pkgs,
  lib,
  netplan,
}:
let
  # Where a machine keeps its ciphertext, across boots.
  store = "/var/lib/ndh/attic-tokens";
  maxBytes = 65536;
  cacheFqdn = lib.concatStringsSep " " (
    lib.mapAttrsToList (ms: bm: "[${ms}]=${lib.escapeShellArg bm.atticFqdn}") netplan.baremetal
  );
in
rec {
  inherit store;

  # paths: the attic client's tmpfs paths. identityMode: keyfile (an age identity file) or hostkey (an ssh host
  # key, converted in memory); identity: its path.
  unseal =
    {
      paths,
      identityMode,
      identity,
    }:
    pkgs.writeShellApplication {
      name = "ndh-attic-tokens-unseal";
      runtimeInputs = [
        pkgs.age
        pkgs.coreutils
        pkgs.ssh-to-age
      ];
      text = ''
        store=${lib.escapeShellArg store}
        dir=${lib.escapeShellArg paths.dir}
        netrc=${lib.escapeShellArg paths.netrc}
        writeToken=${lib.escapeShellArg paths.writeToken}
        identityMode=${lib.escapeShellArg identityMode}
        identity=${lib.escapeShellArg identity}
        declare -A cacheFqdn=(${cacheFqdn})
      ''
      + builtins.readFile ./unseal.sh;
    };

  receive =
    { machine, unsealer }:
    pkgs.writeShellApplication {
      name = "ndh-attic-tokens-receive";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        machine=${lib.escapeShellArg machine}
        store=${lib.escapeShellArg store}
        maxBytes=${toString maxBytes}
        unseal=${lib.getExe unsealer}
        declare -A cacheFqdn=(${cacheFqdn})
      ''
      + builtins.readFile ./receive.sh;
    };

  # targets: [ { name; kind; ssh; } ], every machine but the seat, by the operator's ssh name for it.
  deposit =
    {
      seat,
      localReceive,
      targets,
    }:
    let
      table =
        attr: lib.concatMapStringsSep " " (t: "[${t.name}]=${lib.escapeShellArg t.${attr}}") targets;
    in
    pkgs.writeShellApplication {
      name = "ndh-attic-tokens-deposit";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.openssh
      ];
      text = ''
        seat=${lib.escapeShellArg seat}
        localSudo=/usr/bin/sudo
        localReceive=${lib.getExe localReceive}
        declare -A targetKind=(${table "kind"}) targetSsh=(${table "ssh"})
      ''
      + builtins.readFile ./deposit.sh;
    };
}
