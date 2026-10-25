# keys-reconcile (see keys-reconcile.sh) on ndh's bash trampoline. Its inputs are frozen into it at evaluation (F5):
# the revision this closure is built from, the batch (every pending host-key slot, in fleet-switch's order, with the
# recorded old public F1 is verified against and the files that gain its recipient), the machine list ndh-switch
# reaches them by, and keys.json. Nothing is read from a working tree or an argument. Then the attic cache keys
# (class attic-cache-key): every declared cache (atticCaches, one per guest that enables ndh.atticCache) whose
# metalspace the catalog records no key for, verified against the guest's RECORDED serving host key. Then the attic
# TLS leaves (class attic-tls-csr): every declared cache, with its recorded leaf (catalog/attic-leaves/<ms>.crt) or
# none; plan itself reads that leaf (no import-from-derivation) and measures only a cache whose leaf is missing, does
# not chain to the authority, or expires within 30 days.
{
  pkgs,
  ndh,
  catalog,
  keys,
  revision,
  machines,
  publishDir,
  hostNames,
  # [ { machine; metalspace; fqdn; dir; } ]: the guests that declare a cache, from their own configurations.
  atticCaches,
  keysJsonTool,
  delegation,
}:
let
  inherit (pkgs) lib;
  roles = import ../host-key.d/slots.nix { inherit lib; };
  queue = import ../ops-queue.d/queue.nix { inherit lib catalog keys; };
  # The files whose every rule carries a host recipient (R1, checks.sops-recipients): a host's age joins them all.
  files = [
    ".secrets"
    "catalog/cache-trust.yaml"
    "modules/home-manager/ssh.d/keys.yaml"
  ];
  batch =
    lib.concatMap (
      machine:
      let
        key = "host-${machine}";
        entry = keys.${key} or { };
        r = roles entry;
      in
      lib.optional (r.pendingName != null) {
        class = "host-key";
        inherit machine key files;
        # Sorted bytewise: the certificate's key id hashes this exact list.
        principals = lib.sort lib.lessThan (
          hostNames.${machine} or (throw "keys-reconcile: no host names for ${machine}")
        );
        slot = r.pendingName;
        # A console bootstrap (§o) has no old key to verify against: its binding is the operator's comparison.
        bootstrap = entry.slots.${r.pendingName}.bootstrap or "";
        oldPublic =
          if (entry.slots.${r.pendingName}.bootstrap or "") == "console" then
            ""
          else if r.current ? public then
            "${entry.type or "ssh-ed25519"} ${r.current.public}"
          else
            "";
      }
    ) queue.order
    ++ lib.concatMap (
      c:
      let
        host = roles (keys."host-${c.machine}" or { });
      in
      lib.optional (!(catalog.privateCaches.entries ? ${c.metalspace})) {
        class = "attic-cache-key";
        inherit (c) machine fqdn dir;
        cache = c.metalspace;
        keyNameRegex = catalog.privateCaches.keyNamePattern c.metalspace;
        # The guest's SERVING slot, as keys.yaml records it: what the statement must be signed by.
        servingPublic =
          if (host.current.state or "") == "serving" then
            "${(keys."host-${c.machine}").type or "ssh-ed25519"} ${host.current.public}"
          else
            "";
      }
    ) atticCaches
    ++ map (
      c:
      let
        host = roles (keys."host-${c.machine}" or { });
        leaf = ../../../catalog/attic-leaves + "/${c.metalspace}.crt";
      in
      {
        class = "attic-tls-csr";
        inherit (c) machine fqdn dir;
        cache = c.metalspace;
        servingPublic =
          if (host.current.state or "") == "serving" then
            "${(keys."host-${c.machine}").type or "ssh-ed25519"} ${host.current.public}"
          else
            "";
        recordedLeaf = if builtins.pathExists leaf then "${leaf}" else "";
      }
    ) atticCaches;
in
ndh.store.installBinScript "keys-reconcile" (
  pkgs.replaceVars ./keys-reconcile.sh {
    nixBashTrampoline = "${ndh.context.nixBashTrampoline}";
    toolPath = lib.makeBinPath [
      pkgs.coreutils
      pkgs.gawk
      pkgs.git
      pkgs.sops
      pkgs.gnugrep
      pkgs.gnused
      pkgs.openssh
      pkgs.openssl
      pkgs.ssh-to-age
      pkgs.step-cli
      pkgs.yq-go
    ];
    revision = lib.escapeShellArg revision;
    remote = lib.escapeShellArg "https://github.com/seedmatic/ndh";
    batch = pkgs.writeText "keys-reconcile-batch.json" (builtins.toJSON batch);
    inherit machines;
    keysJson = ../../home-manager/ssh.d/keys.json;
    publishDir = lib.escapeShellArg publishDir;
    verify = ./verify.sh;
    declare = ./declare.sh;
    write = ./write.sh;
    classes = ./classes;
    delegation = lib.escapeShellArg delegation;
    inherit keysJsonTool;
    ttyIn = "/dev/tty";
    ttyOut = "/dev/tty";
  }
)
// {
  passthru = { inherit batch; };
}
