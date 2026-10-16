# Roles × keys S3a: every name each fleet machine answers to, per machine, the set its ONE host
# certificate is signed for (ssh-keys-certify). An inventory host, and each guest read from its own
# configuration (vm.guestHostName, and vm.guestName.vm.hostName, the bare-metal's dnsmasq zone), in the
# bare, .lan, .local and <ssh authority domain> forms. A name two machines claimed would let either
# answer as the other under a certificate the clients trust, so it is refused here, at evaluation.
{ lib }:
{
  domain,
  hosts,
  guests,
}:
let
  forms = name: [
    name
    "${name}.lan"
    "${name}.local"
    "${name}.${domain}"
  ];
  guestMachines = map (vm: vm.guestHostName) guests;
  byMachine =
    lib.genAttrs hosts forms
    // lib.listToAttrs (
      map (
        vm:
        lib.nameValuePair vm.guestHostName (forms vm.guestHostName ++ [ "${vm.guestName}.${vm.hostName}" ])
      ) guests
    );
  machinesOf = lib.groupBy (claim: claim.name) (
    lib.concatLists (
      lib.mapAttrsToList (
        machine: names: map (name: { inherit name machine; }) (lib.unique names)
      ) byMachine
    )
  );
  shared = lib.filterAttrs (_: claims: lib.length claims > 1) machinesOf;
  twice = lib.filter (m: lib.count (n: n == m) (hosts ++ guestMachines) > 1) (
    lib.unique (hosts ++ guestMachines)
  );
in
if twice != [ ] then
  throw "fleet host names: machine declared twice: ${lib.concatStringsSep ", " twice}"
else if shared != { } then
  throw "fleet host names: a name belongs to more than one machine: ${
    lib.concatStringsSep "; " (
      lib.mapAttrsToList (
        name: claims: "${name} (${lib.concatStringsSep ", " (map (c: c.machine) claims)})"
      ) shared
    )
  }"
else
  lib.mapAttrs (_: names: lib.sort lib.lessThan (lib.unique names)) byMachine
