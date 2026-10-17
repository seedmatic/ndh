# ndh-ops (see ndh-ops.sh). tools: an attrset name → executable store path, one per entry of verbs.json's
# operator_tools and operator_apply; the flake builds it from the same packages as the tools' own apps.
{ pkgs, tools }:
let
  inherit (pkgs) lib;
  verbs = builtins.fromJSON (builtins.readFile ../../darwin/claude-code-managed.d/verbs.json);
  operatorTools = verbs.operator_tools.programs ++ verbs.operator_apply.programs;
in
assert lib.assertMsg (
  lib.sort lib.lessThan (builtins.attrNames tools) == lib.sort lib.lessThan operatorTools
) "ndh-ops: its tools must be exactly verbs.json's operator_tools and operator_apply";
pkgs.writeShellApplication {
  name = "ndh-ops";
  runtimeInputs = with pkgs; [
    coreutils
    gnused
  ];
  text = ''
    dir=/var/db/ndh-ops
    sudo=/usr/bin/sudo
    max_hours=72
    declare -A tools=(${
      lib.concatStrings (lib.mapAttrsToList (n: p: "[${n}]=${lib.escapeShellArg p} ") tools)
    })
  ''
  + builtins.readFile ./ndh-ops.sh;
}
