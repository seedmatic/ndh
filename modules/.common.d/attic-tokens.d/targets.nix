# Who gets an attic token, one definition for both sides: the cache container that mints them (attic-cache.nix) and
# every machine that pulls its own (attic-client.nix). Each metalspace's two machines, its darwin host and its NixOS
# guest, share one access point: their tokens are sealed to the age recipient of that seat's host key, its CURRENT
# slot (slots.nix), never the newest — a pending slot's public is unverified until keys-reconcile's window. A seat with
# no current slot yet is left out: its machines wait for it.
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
    let
      entry = keys."host-${host}" or { };
      current = (roles entry).current;
      publicKey = "${entry.type or "ssh-ed25519"} ${current.public}";
    in
    lib.optionals (current ? public) (
      map
        (machine: {
          inherit machine publicKey;
          metalspace = host;
          dir = builtins.hashString "sha256" "${machine} ${publicKey}";
        })
        [
          host
          bm.nixosHostname
        ]
    )
  ) (netplan.baremetal or { })
)
