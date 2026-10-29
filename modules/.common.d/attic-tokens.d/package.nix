# The attic token delivery (F6), one definition for every machine: the pull (fetch.sh), which takes this machine's
# own tokens from every cache it reads, and the unseal (unseal.sh), which decrypts and checks them; built for one machine.
{
  pkgs,
  lib,
  netplan,
  # The TLS leaves keys-reconcile recorded, <metalspace>.crt each: a cache without one serves nothing (its nginx waits).
  leaves ? ../../../catalog/attic-leaves,
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

  # The caches that can answer: those whose leaf is recorded. A machine pulls from these alone, and while there is
  # none, its delivery is not installed: it waits, as nginx does, instead of failing at every switch.
  served = lib.filterAttrs (ms: _: builtins.pathExists (leaves + "/${ms}.crt")) netplan.baremetal;
  # Said at every activation, once per cache still waiting: the missing leaf is the operator's next gesture.
  waitingNotice = lib.concatStrings (
    lib.mapAttrsToList (
      _: bm:
      "echo ${lib.escapeShellArg "[attic] no TLS leaf recorded for ${bm.atticFqdn}: this machine does not pull from it; next gesture: keys-reconcile window (class attic-tls-csr)"} >&2\n"
    ) (removeAttrs netplan.baremetal (lib.attrNames served))
  );

  # paths: the attic client's tmpfs paths. writeTokenOwner: the account write.token is given to. identityMode: keyfile (an age identity file) or hostkey (an ssh host
  # key, converted in memory); identity: its path.
  unseal =
    {
      paths,
      writeTokenOwner,
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
        writeTokenOwner=${lib.escapeShellArg writeTokenOwner}
        identityMode=${lib.escapeShellArg identityMode}
        identity=${lib.escapeShellArg identity}
        declare -A cacheFqdn=(${cacheFqdn})
      ''
      + builtins.readFile ./unseal.sh;
    };

  # The pull (F6): machine, its own metalspace (its write token comes from that cache alone), keys (keys.yaml's, for
  # its served directory), tlsRoots (the fleet TLS authority's trusted ca_crt PEMs: the ONLY roots the pull accepts,
  # never the system store, which holds every public CA), unsealer.
  fetch =
    {
      machine,
      metalspace,
      keys,
      tlsRoots,
      unsealer,
    }:
    let
      cacert = pkgs.writeText "ndh-attic-tokens-tls-roots.pem" (lib.concatStringsSep "\n" tlsRoots);
      targets = import ./targets.nix { inherit lib keys netplan; };
      mine = lib.findFirst (t: t.machine == machine) null targets;
      caches = lib.concatStringsSep " " (
        lib.mapAttrsToList (ms: bm: "[${ms}]=${lib.escapeShellArg bm.atticFqdn}") served
      );
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
        cacert=${lib.escapeShellArg cacert}
        staleAfter=10
        unseal=${lib.getExe unsealer}
        declare -A caches=(${caches})
      ''
      + builtins.readFile ./fetch.sh;
    };
}
