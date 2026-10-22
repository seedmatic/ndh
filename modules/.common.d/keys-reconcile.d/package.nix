# keys-reconcile (see keys-reconcile.sh) on ndh's bash trampoline. Its inputs are frozen into it at evaluation (F5):
# the revision this closure is built from, the batch (every pending host-key slot, in fleet-switch's order, with the
# recorded old public F1 is verified against and the files that gain its recipient), the machine list ndh-switch
# reaches them by, and keys.json. Nothing is read from a working tree or an argument.
{
  pkgs,
  ndh,
  catalog,
  keys,
  revision,
  machines,
  publishDir,
  hostNames,
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
  batch = lib.concatMap (
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
      oldPublic = if r.current ? public then "${entry.type or "ssh-ed25519"} ${r.current.public}" else "";
    }
  ) queue.order;
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
      pkgs.ssh-to-age
      pkgs.yq-go
    ];
    revision = lib.escapeShellArg revision;
    remote = lib.escapeShellArg "https://github.com/seedmatic/ndh";
    batch = pkgs.writeText "keys-reconcile-batch.json" (builtins.toJSON batch);
    inherit machines;
    keysJson = ../../home-manager/ssh.d/keys.json;
    publishDir = lib.escapeShellArg publishDir;
    verify = ./verify.sh;
    write = ./write.sh;
    delegation = lib.escapeShellArg delegation;
    inherit keysJsonTool;
    ttyIn = "/dev/tty";
    ttyOut = "/dev/tty";
  }
)
// {
  passthru = { inherit batch; };
}
