# ndh-attic-tokens-unseal (unseal.sh), built for one machine: where its ciphertext rests, the attic client's
# tmpfs paths, and how its identity decrypts. One definition for the NixOS guests and the darwin hosts.
{
  pkgs,
  lib,
  netplan,
  paths,
  identityMode,
  identity,
}:
let
  # Where the token delivery keeps this machine's ciphertext, across boots.
  store = "/var/lib/ndh/attic-tokens";
  cacheFqdn = lib.concatStringsSep " " (
    lib.mapAttrsToList (ms: bm: "[${ms}]=${lib.escapeShellArg bm.atticFqdn}") netplan.baremetal
  );
in
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
}
// {
  inherit store;
}
