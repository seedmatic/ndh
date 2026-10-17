# bats-lint as a flake check: no bats test of the repository carries a line that checks nothing mid-test. The two
# fixtures prove the lint itself first: every weak form refused, every checking form accepted.
{ pkgs, src }:
pkgs.runCommand "bats-weak-lines"
  {
    nativeBuildInputs = [
      pkgs.gawk
      pkgs.findutils
    ];
  }
  ''
    lint=${./bats-lint.awk}
    if awk -f "$lint" ${./tests/weak.bats} >weak.out; then
      echo "FAIL: the lint accepted the weak fixture" >&2
      exit 1
    fi
    [ "$(wc -l <weak.out)" -eq 3 ] || { echo "FAIL: the lint did not refuse all 3 weak forms" >&2; cat weak.out >&2; exit 1; }
    awk -f "$lint" ${./tests/strong.bats} || { echo "FAIL: the lint refused a checking form" >&2; exit 1; }
    cd ${src}
    find . -name '*.bats' -not -path './modules/.common.d/bats-lint.d/tests/weak.bats' -print0 |
      xargs -0 awk -f "$lint"
    touch $out
  ''
