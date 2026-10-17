# ndh-ops's bats suite as a flake check: the real script, a throwaway delegation directory, stub tools. It also
# builds the package itself (stub tools, the real operator_tools and operator_apply names), so its shellcheck runs
# with the check.
{ pkgs }:
let
  verbs = builtins.fromJSON (builtins.readFile ../../../darwin/claude-code-managed.d/verbs.json);
  operatorTools = verbs.operator_tools.programs ++ verbs.operator_apply.programs;
  package = import ../package.nix {
    inherit pkgs;
    tools = pkgs.lib.genAttrs operatorTools (_: "${pkgs.coreutils}/bin/true");
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
    cp -r ${../.} ndh-ops.d && chmod -R u+w ndh-ops.d
    cd ndh-ops.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
