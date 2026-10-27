#!/usr/bin/env bats
# A recursive reader whose root holds an EXISTING protected directory (.pulumi-state): a copy of the hook beside a
# verbs.json whose protected_scan_bares names a throwaway bare repository, which lists a fake worktree holding the
# state. Nothing here runs the commands under test: the hook only answers.

setup() {
  T="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  mkdir -p "$T/hook" "$T/state"
  cp "$BATS_TEST_DIRNAME/../deny-hook.py" "$T/hook/"
  B="$T/bares" yq -p=json -o=json '.protected_scan_bares = [strenv(B)]' "$BATS_TEST_DIRNAME/../verbs.json" >"$T/hook/verbs.json"
  export HOME=/Users/tester XDG_STATE_HOME="$T/state"
  W="$T/wt"
  mkdir -p "$W/.pulumi-state/.pulumi/stacks" "$W/src/deep" "$T/bares/repo.git/worktrees/wt"
  : >"$W/.pulumi-state/.pulumi/stacks/dev.json"
  printf '%s\n' "$W/.git" >"$T/bares/repo.git/worktrees/wt/gitdir"
}

hook() {
  C="$1" yq -n -o=json '{"hook_event_name":"PreToolUse", "tool_name":"Bash", "tool_input":{"command":strenv(C)}, "cwd":"/tmp/work"}' |
    python3 "$T/hook/deny-hook.py"
}
denied()  { [ "$status" -eq 2 ] || { echo "expected deny, got status=$status output=$output"; return 1; }; }
allowed() { [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "expected allow, got status=$status output=$output"; return 1; }; }

@test "walk: grep -r above the state"         { run hook "grep -r token $W"; denied; }
@test "walk: grep -rn from the worktree root" { run hook "cd $W && grep -rn token ."; denied; }
@test "walk: grep -R from a parent"           { run hook "grep -R token $T"; denied; }
@test "walk: rg --hidden"                     { run hook "rg --hidden token $W"; denied; }
@test "walk: rg -uu"                          { run hook "rg -uu token $W"; denied; }
@test "walk: tar c of the worktree"           { run hook "tar czf /tmp/x.tgz $W"; denied; }
@test "walk: cp -r of the worktree"           { run hook "cp -r $W /tmp/copy"; denied; }
@test "walk: rsync of the worktree"           { run hook "rsync -a $W/ /tmp/copy/"; denied; }
@test "walk: scp -r of the worktree"          { run hook "scp -r $W host:/tmp/"; denied; }
@test "walk: zip -r of the worktree"          { run hook "zip -r /tmp/x.zip $W"; denied; }
@test "walk: ditto of the worktree"           { run hook "ditto $W /tmp/copy"; denied; }
@test "walk: git grep --untracked"            { run hook "cd $W && git grep --untracked token"; denied; }
@test "walk: git -C grep --untracked"         { run hook "git -C $W grep --untracked token"; denied; }
@test "walk: git -C chained"                  { run hook "git -C $T -C wt grep --untracked token"; denied; }
@test "walk: git --work-tree= grep --no-index" { run hook "git --work-tree=$W grep --no-index token"; denied; }
@test "ok git -C grep, tracked files only"    { run hook "git -C $W grep token"; allowed; }
@test "walk: find -exec cat" {
  run hook "find $W -name '*.json' -exec cat {} +"
  denied
}
@test "walk: an unresolvable root is refused" { run hook 'grep -r token $d'; denied; }
# Plain rg skips hidden names only by default: a config file (RIPGREP_CONFIG_PATH) can add --hidden unseen.
@test "walk: plain rg"                        { run hook "rg token $W"; denied; }
@test "ok grep -r below the state's level"    { run hook "grep -r token $W/src"; allowed; }
@test "ok grep without -r at the root"        { run hook "grep token $W/README"; allowed; }
@test "ok cp without -r"                      { run hook "cp $W/README /tmp/r"; allowed; }
@test "ok find that reads nothing"            { run hook "find $W -name '*.md' -print"; allowed; }
