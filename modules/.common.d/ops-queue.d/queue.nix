# The operator's queue (roles × keys K2): the migration's steps, per machine and in fleet-switch's order, DERIVED
# from keys.yaml's machine slots (<m>, sshfs-<m>), so no step is recorded by hand. A slot goes through the queue
# only when it was born on its machine (`origin: host`, K3); a keyring slot is never offered, it waits for a
# declaration and retires with the next migration (design §d).
#
# Per machine key, the step it waits for, read from slots.nix's roles (K3):
#   a pending slot                                   → generate (M2: switch the machine, its activation generates and
#                                                      publishes), then the window (M3: keys-reconcile apply, K4)
#   current `recorded`, origin host                  → serve    (M5: switch the machine, it serves the new slot)
# A slot never rests between generate and the window: keys.yaml cannot learn that a machine generated (the machine
# commits nothing), so the batch stays at `generate` until keys-reconcile plan measures every machine's publication
# (F1-verified), and the window's « yes » takes the slots from pending to recorded at once (K4, design §k).
# An entry is { step, key, machine, slot, checked, unchecked, does }: `checked` = the preconditions K2 reads in the
# declaration and found unmet (empty: met), `unchecked` = those it cannot measure, shown as « non vérifié ».
{
  lib,
  catalog,
  keys,
}:
let
  roles = import ../host-key.d/slots.nix { inherit lib; };

  # fleet-switch's order (fleet-switch.sh): the NixOS guests, the darwin hosts but the seat, the seat last.
  order =
    let
      ms = catalog.machines;
    in
    map (m: m.name) (
      lib.filter (m: m.kind == "nixos") ms
      ++ lib.filter (m: m.kind == "darwin" && !(m.seat or false)) ms
      ++ lib.filter (m: m.kind == "darwin" && (m.seat or false)) ms
    );

  machineKeys = lib.concatMap (
    machine:
    lib.concatMap
      (
        key:
        lib.optional (keys ? ${key}) {
          inherit key machine;
        }
      )
      [
        machine
        "sshfs-${machine}"
      ]
  ) order;

  slotsOf = k: keys.${k.key}.slots or { };
  roleOf = k: roles keys.${k.key};

  entryOf =
    k:
    let
      r = roleOf k;
      cur = r.current;
      origin = cur.origin or "";
    in
    if r.pendingName != null then
      {
        step = "generate";
        inherit (k) key machine;
        slot = r.pendingName;
        checked = [ ];
        unchecked = [
          "${k.machine} reachable"
          "${k.key}@${r.pendingName}'s public published and verified (keys-reconcile plan)"
        ];
        does = "switch ${k.machine}: its activation generates the key ${k.key}@${r.pendingName} and publishes its public; then the window (keys-reconcile)";
      }
    else if (cur.state or "") == "recorded" && origin == "host" then
      {
        step = "serve";
        inherit (k) key machine;
        slot = r.currentName;
        checked = [ ];
        unchecked = [ "${k.machine} reachable" ];
        does = "switch ${k.machine}: it serves ${k.key}@${r.currentName}";
      }
    else
      null;

  # Keyring slots that are not serving and have no pending successor: listed, never offered.
  waiting = lib.concatMap (
    k:
    let
      r = roleOf k;
    in
    lib.optional
      (
        r.pendingName == null
        && (r.current.origin or "") == "keyring"
        && (r.current.state or "") == "recorded"
      )
      {
        inherit (k) key machine;
        slot = r.currentName;
        state = r.current.state;
      }
  ) machineKeys;

  # The steps run one batch at a time: every machine generates (and the window records them all) before any
  # machine serves. So the queue holds the earliest step present, its machines in fleet-switch's order.
  steps = lib.filter (e: e != null) (map entryOf machineKeys);
  rank =
    s:
    lib.lists.findFirstIndex (x: x == s) 99 [
      "generate"
      "serve"
    ];
  first = lib.foldl' (acc: e: lib.min acc (rank e.step)) 99 steps;
  later = lib.filter (e: rank e.step > first) steps;
in
assert lib.assertMsg (lib.all (
  k: lib.all (s: s.origin or null != null) (lib.attrValues (slotsOf k))
) machineKeys) "ops queue: a machine slot without `origin` (K1 makes it required)";
{
  inherit order waiting;
  head = lib.filter (e: rank e.step == first) steps;
  blocked = map (
    e:
    e
    // {
      checked = e.checked ++ [ "the previous step is not done on the whole fleet" ];
    }
  ) later;
}
