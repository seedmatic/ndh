# ndh-ops's bats suite as a flake check: the real script, a throwaway delegation directory, stub tools. It also
# builds the package itself (stub tools, the real operator_tools names less never_delegated), so its shellcheck
# runs with the check, and asserts no never-delegated tool is in its table.
{ pkgs }:
let
  verbs = builtins.fromJSON (builtins.readFile ../../../darwin/claude-code-managed.d/verbs.json);
  inherit (pkgs) lib;
  neverDelegated = verbs.operator_tools.never_delegated;
  operatorTools = lib.subtractLists neverDelegated verbs.operator_tools.programs;
  package = import ../package.nix {
    inherit pkgs;
    tools = lib.genAttrs operatorTools (_: "${pkgs.coreutils}/bin/true");
  };
in
pkgs.runCommand "ndh-ops-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      gnused
    ];
  }
  ''
    test -x ${package}/bin/ndh-ops
    grep -qF '[${builtins.head operatorTools}]=' ${package}/bin/ndh-ops
    ${lib.concatMapStrings (
      n: "! grep -qF '[${n}]=' ${package}/bin/ndh-ops || exit 1\n"
    ) neverDelegated}
    cp -r ${../.} ndh-ops.d && chmod -R u+w ndh-ops.d
    cd ndh-ops.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
