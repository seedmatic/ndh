# The operator's queue (roles × keys K2): the migration's steps, per machine and in fleet-switch's order, DERIVED
# from keys.yaml's machine slots (host-<m>, sshfs-<m>), so no step is recorded by hand. A slot goes through the queue
# only when it was born on its machine (`origin: host`, K3); a keyring slot is never offered, it waits for a
# declaration and retires with the next migration (design §d).
#
# Per machine key, the step it waits for, read from slots.nix's roles (K3):
#   a pending slot                                   → generate (M2: switch the machine, its activation generates)
#   current `generated`                              → window   (M3: record + certify + re-key; K4)
#   current `recorded`, origin host                  → serve    (M5: switch the machine, it serves the new slot)
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
        kind:
        lib.optional (keys ? "${kind}-${machine}") {
          key = "${kind}-${machine}";
          inherit machine;
        }
      )
      [
        "host"
        "sshfs"
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
        unchecked = [ "${k.machine} joignable" ];
        does = "basculer ${k.machine} : son activation génère la clé ${k.key}@${r.pendingName} et publie sa publique";
      }
    else if (cur.state or "") == "generated" && origin == "host" then
      {
        step = "window";
        inherit (k) key machine;
        slot = r.currentName;
        checked = [ "le pas « ouvrir la fenêtre » arrive avec K4 (keys-reconcile)" ];
        unchecked = [ "la publique de ${k.key}@${r.currentName} publiée par ${k.machine}" ];
        does = "ouvrir la fenêtre : enregistrer et certifier ${k.key}@${r.currentName}, re-chiffrer ses fichiers";
      }
    else if (cur.state or "") == "recorded" && origin == "host" then
      {
        step = "serve";
        inherit (k) key machine;
        slot = r.currentName;
        checked = [ ];
        unchecked = [ "${k.machine} joignable" ];
        does = "basculer ${k.machine} : il sert ${k.key}@${r.currentName}";
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
        && lib.elem (r.current.state or "") [
          "generated"
          "recorded"
        ]
      )
      {
        inherit (k) key machine;
        slot = r.currentName;
        state = r.current.state;
      }
  ) machineKeys;

  # The steps run one batch at a time: every machine generates before the window, the window closes before any
  # machine serves. So the queue holds the earliest step present, its machines in fleet-switch's order.
  steps = lib.filter (e: e != null) (map entryOf machineKeys);
  rank =
    s:
    lib.lists.findFirstIndex (x: x == s) 99 [
      "generate"
      "window"
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
      checked = e.checked ++ [ "le pas précédent n'est pas fini sur toute la flotte" ];
    }
  ) later;
}
