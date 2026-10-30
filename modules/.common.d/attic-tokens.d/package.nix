# The attic token delivery (F6), one definition for every machine: the pull (fetch.sh), which takes this machine's
# own tokens from every cache it reads, and the unseal (unseal.sh), which decrypts and checks them; built for one machine.
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

  # paths: the attic client's tmpfs paths. writeTokenOwner: the account write.token is given to. identity: this machine's ssh host key, converted in
  # memory (its tokens are sealed to it).
  unseal =
    {
      paths,
      writeTokenOwner,
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
        writeTokenOwner=${lib.escapeShellArg writeTokenOwner}
        identity=${lib.escapeShellArg identity}
        declare -A cacheFqdn=(${cacheFqdn})
      ''
      + builtins.readFile ./unseal.sh;
    };

  # The pull (F6): machine, its own metalspace (its write token comes from that cache alone), keys (keys.yaml's, for
  # its served directory), unsealer.
  fetch =
    {
      machine,
      metalspace,
      keys,
      unsealer,
    }:
    let
      targets = import ./targets.nix { inherit lib keys netplan; };
      mine = lib.findFirst (t: t.machine == machine) null targets;
    in
    pkgs.writeShellApplication {
      name = "ndh-attic-tokens-fetch";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.curl
        pkgs.diffutils
        pkgs.findutils
        pkgs.gnugrep
      ];
      text = ''
        machine=${lib.escapeShellArg machine}
        own=${lib.escapeShellArg metalspace}
        store=${lib.escapeShellArg store}
        dir=${lib.escapeShellArg (if mine == null then "" else mine.dir)}
        maxBytes=${toString maxBytes}
        staleAfter=10
        unseal=${lib.getExe unsealer}
        declare -A caches=(${cacheFqdn})
      ''
      + builtins.readFile ./fetch.sh;
    };
}
