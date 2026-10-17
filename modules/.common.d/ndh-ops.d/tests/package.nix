# ndh-ops's bats suite as a flake check: the real script, a throwaway delegation directory, stub tools. It also
# builds the package itself (stub tools, the real operator_tools names), so its shellcheck runs with the check.
{ pkgs }:
let
  operatorTools =
    (builtins.fromJSON (builtins.readFile ../../../darwin/claude-code-managed.d/verbs.json))
    .operator_tools.programs;
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
