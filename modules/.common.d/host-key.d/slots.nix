# A key's slots by role (roles × keys K3): `current` is the newest slot that holds a key the machine may use — not
# `pending` (declared, no key yet) and not `retired` — and `pending` is the one declared for the machine to generate,
# or null. Slots are named by date, so the last name sorts newest. Every reader of "the slot a machine serves" goes
# through `current`: a pending slot, newer by construction, must never be taken for it.
{ lib }:
entry:
let
  slots = entry.slots or { };
  named =
    state:
    lib.filter (n: (slots.${n}.state or "") == state) (lib.sort lib.lessThan (lib.attrNames slots));
  usable = lib.filter (
    n:
    !(lib.elem (slots.${n}.state or "") [
      "pending"
      "retired"
    ])
  ) (lib.sort lib.lessThan (lib.attrNames slots));
  pendingNames = named "pending";
in
{
  currentName = if usable == [ ] then null else lib.last usable;
  current = if usable == [ ] then { } else slots.${lib.last usable};
  pendingName =
    if lib.length pendingNames > 1 then
      throw "keys.yaml: ${entry.comment or "a key"} has ${toString (lib.length pendingNames)} pending slots (${lib.concatStringsSep ", " pendingNames}); one at a time"
    else if pendingNames == [ ] then
      null
    else
      lib.head pendingNames;
}
