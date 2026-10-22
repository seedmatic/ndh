# ndh-store's gestures as a flake check: every system tool stubbed, the refusal-changes-nothing rule. The program
# runs with exactly the wrapper's tools on its path (runtime-inputs.nix), so a tool the wrapper lacks fails here.
{ pkgs }:
let
  runtimeInputs = import ../runtime-inputs.nix { inherit pkgs; };
in
pkgs.runCommand "store-freeze-bats"
  {
    nativeBuildInputs = with pkgs; [
      bash
      bats
      coreutils
    ];
    TOOLS_PATH = pkgs.lib.makeBinPath runtimeInputs.tools;
    # ndh-store-commit's own tools, as store-freeze.nix gives them: the suite runs it with exactly these.
    COMMIT_TOOLS_PATH = pkgs.lib.makeBinPath runtimeInputs.commit;
  }
  ''
    cp -r ${./..} store-freeze.d && chmod -R u+w store-freeze.d
    cd store-freeze.d/tests
    HOME=$TMPDIR bats --print-output-on-failure cli.bats
    HOME=$TMPDIR TOOLS_PATH=$COMMIT_TOOLS_PATH bats --print-output-on-failure commit.bats
    touch $out
  ''
