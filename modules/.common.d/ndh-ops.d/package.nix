# ndh-ops (see ndh-ops.sh). tools: an attrset name → executable store path, one per entry of verbs.json's
# operator_tools but those never delegated; the flake builds it from the same packages as the tools' own apps.
{ pkgs, tools }:
let
  inherit (pkgs) lib;
  inherit (import ./paths.nix) dir;
  verbs = builtins.fromJSON (builtins.readFile ../../darwin/claude-code-managed.d/verbs.json);
  # never_delegated (the root's ceremony): the operator's alone, at a terminal; no armed delegation may run it.
  operatorTools = lib.subtractLists verbs.operator_tools.never_delegated verbs.operator_tools.programs;
in
assert lib.assertMsg (
  lib.sort lib.lessThan (builtins.attrNames tools) == lib.sort lib.lessThan operatorTools
) "ndh-ops: its tools must be exactly verbs.json's operator_tools, less never_delegated";
pkgs.writeShellApplication {
  name = "ndh-ops";
  runtimeInputs = with pkgs; [
    coreutils
    gnused
  ];
  text = ''
    dir=${lib.escapeShellArg dir}
    sudo=/usr/bin/sudo
    max_hours=72
    declare -A tools=(${
      lib.concatStrings (lib.mapAttrsToList (n: p: "[${n}]=${lib.escapeShellArg p} ") tools)
    })
  ''
  + builtins.readFile ./ndh-ops.sh;
}
