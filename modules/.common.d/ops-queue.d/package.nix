# ops (see ops.sh) on ndh's bash trampoline, with the queue queue.nix derives from keys.yaml frozen into it.
{
  pkgs,
  ndh,
  catalog,
  keys,
  # keys-reconcile (its plan and window) and ndh-ops (the delegation the window runs under), by store path.
  keysReconcile,
  ndhOps,
}:
let
  queue = import ./queue.nix {
    inherit (pkgs) lib;
    inherit catalog keys;
  };
in
(ndh.store.installBinScript "ops" (
  pkgs.replaceVars ./ops.sh {
    nixBashTrampoline = "${ndh.context.nixBashTrampoline}";
    loggerTag = "ndh.ops";
    toolPath = pkgs.lib.makeBinPath [
      pkgs.coreutils
      pkgs.yq-go
    ];
    queue = pkgs.writeText "ops-queue.json" (builtins.toJSON queue);
    inherit keysReconcile ndhOps;
  }
))
// {
  passthru = { inherit queue; };
}
