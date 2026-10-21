# ops (see ops.sh) on ndh's bash trampoline, with the queue queue.nix derives from keys.yaml frozen into it.
{
  pkgs,
  ndh,
  catalog,
  keys,
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
  }
))
// {
  passthru = { inherit queue; };
}
