# secret-xtrace-guard's mutants as a flake check: each rule's fixture lands in its class, each clean form in none.
{ pkgs }:
pkgs.runCommand "secret-xtrace-guard-mutants"
  {
    # The one real script a mutant is cut from: hs-lib, whose window the check must miss when removed.
    HS_LIB = ../../../darwin/headscale-tools/hs-lib.sh;
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      shfmt
      python3
    ];
  }
  ''
    cp -r ${./..} guard && chmod -R u+w guard
    cd guard/tests && HOME=$TMPDIR bats --print-output-on-failure mutants.bats
    touch $out
  ''
