# no-jq (scan.py) as a flake check, over the repo at the revision: any jq outside the initrd exception fails it. A
# mutant runs every time: a jq command added to a script of no exception must be found, and fail the scan.
{
  pkgs,
  src,
}:
pkgs.runCommand "no-jq"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    # The scanner's status IS the check's: never behind a pipe.
    rc=0
    python3 -I ${./scan.py} ${src} >$TMPDIR/report || rc=$?
    cat $TMPDIR/report
    [ "$rc" = 0 ] || exit "$rc"
    # The mutant: the tree with one jq added to a script of no exception.
    cp -r ${src} tree && chmod -R u+w tree
    printf '%s\n' 'x=$(printf "{}" | jq -r .k)' >>tree/modules/nixos/store-freeze.d/commit.sh
    if python3 -I ${./scan.py} tree >$TMPDIR/mutant; then
      echo "no-jq: the mutant (a jq added to commit.sh) was NOT refused" >&2; exit 1
    fi
    grep -q 'store-freeze.d/commit.sh' $TMPDIR/mutant || { echo "no-jq: the mutant was refused without naming its line" >&2; exit 1; }
    mkdir -p $out && cp $TMPDIR/report $out/report
  ''
