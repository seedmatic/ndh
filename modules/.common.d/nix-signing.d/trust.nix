# The fleet's nix signing publics (roles × keys B2): every nixSigning a host key's slot records. keys.yaml
# holds current slots only (a superseded slot is deleted in the change that revokes it, and keys-yaml.nix
# refuses a revoked public still carried by a slot), so a cut machine leaves this list in the same edit.
{ lib }:
keys:
lib.concatLists (
  lib.mapAttrsToList (
    name: key:
    lib.optionals (lib.hasPrefix "host-" name) (
      lib.mapAttrsToList (_slot: s: s.nixSigning) (
        lib.filterAttrs (_slot: s: s ? nixSigning) (key.slots or { })
      )
    )
  ) keys
)
