# Who gets an attic token, one definition for both sides: the cache container that mints them (attic-cache.nix) and
# every machine that pulls its own (attic-client.nix). Each metalspace's two machines, its darwin host and its NixOS
# guest, are each sealed to the age recipient of their OWN host key (a key born on the machine, which is what it
# decrypts with), its CURRENT slot (slots.nix), never the newest — a pending slot's public is unverified until
# keys-reconcile's window. A machine with no current slot yet is left out: it waits for it.
#
# Each target's tokens are served under `dir`, a hash of the machine and its public, so the served tree names no
# machine; both sides compute it here, at evaluation.
{
  lib,
  keys,
  netplan,
}:
let
  roles = import ../host-key.d/slots.nix { inherit lib; };
in
lib.concatLists (
  lib.mapAttrsToList (
    host: bm:
    lib.concatMap
      (
        machine:
        let
          entry = keys.${machine} or { };
          current = (roles entry).current;
          publicKey = "${entry.type or "ssh-ed25519"} ${current.public}";
        in
        lib.optional (current ? public) {
          inherit machine publicKey;
          metalspace = host;
          dir = builtins.hashString "sha256" "${machine} ${publicKey}";
        }
      )
      [
        host
        bm.nixosHostname
      ]
  ) (netplan.baremetal or { })
)
