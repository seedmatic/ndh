#!/usr/bin/env bats
# The deletion areas: a copy of the hook beside a fixture owned-dirs.json, two sessions, real directories under the
# test's tmp dir for the on-disk exclude. Nothing here removes anything: the hook only answers.

setup() {
  # Its real path: on macOS the tmp dir sits under /var, a symlink, and the hook checks real paths.
  T="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  mkdir -p "$T/hook" "$T/state"
  cp "$BATS_TEST_DIRNAME/../deny-hook.py" "$BATS_TEST_DIRNAME/../verbs.json" "$T/hook/"
  export HOME=/Users/tester XDG_STATE_HOME="$T/state"
  A="$T/areas"
  mkdir -p "$A/mine/probe" "$A/mine/logs" "$A/mine/vault" "$A/theirs/x" "$A/bare/sub"
  touch "$A/mine/vault/.secrets" "$A/mine/logs/redact.sh"
  mkdir -p "$T/elsewhere" "$A/probe-root/x"; touch "$T/elsewhere/f"
  ln -s "$A/mine/vault" "$A/mine/link-vault"
  ln -s "$T/elsewhere" "$A/mine/hop"
  cat >"$T/hook/owned-dirs.json" <<EOF
{
  "pages_never_remove": ["~/.claude/.scratchpad.d/*/LIVE.md"],
  "global_exclude": ["~", "/Volumes/git-bare-store/**", "**/.secrets", "**/.secrets/**", "$A/frozen/**"],
  "sessions": {
    "mine": {
      "owned": ["$A/mine/**", "$A/bare/**", "$A/probe-root", "$A/probe-root/**", "~/.claude/.scratchpad.d/topic/**", "/private/tmp/mine-{a,b}.*", "/private/tmp/run{1..3}"],
      "worktrees": ["/Volumes/git-worktree-store/seedmatic/ndh.d/*/*"],
      "exclude": ["$A/mine/logs/redact.sh"],
      "conversations": ["11111111-0000-0000-0000-000000000001"]
    },
    "theirs": {
      "owned": ["$A/theirs/**", "~/.claude/.scratchpad.d/their-topic/**"],
      "conversations": ["22222222-0000-0000-0000-000000000002"]
    }
  }
}
EOF
}

as() { # $1 = session id, $2 = command
  jq -n --arg c "$2" --arg s "$1" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}, cwd:"/tmp/work", session_id:$s}' |
    python3 "$T/hook/deny-hook.py"
}
MINE=11111111-0000-0000-0000-000000000001
allowed_owned() { [ "$status" -eq 0 ] && [[ "$output" == *'"permissionDecision": "allow"'* ]] || { echo "expected owned allow, got status=$status output=$output"; return 1; }; }
not_allowed()   { [[ "$output" != *'"permissionDecision": "allow"'* ]] || { echo "expected no allow, got $output"; return 1; }; }

@test "owned: one exact path in my area is removed without a prompt, and audited with the session id" {
  run as "$MINE" "rm -rf $A/mine/probe"
  allowed_owned
  grep -q "mine $MINE removes $A/mine/probe ($A/mine/\*\*)" "$T/state/claude-deny-hook/log"
}
@test "owned: a scratchpad topic of mine, after a cd elsewhere" {
  run as "$MINE" "cd ~ && rm -rf ~/.claude/.scratchpad.d/topic/old-draft"
  allowed_owned
}
@test "owned: braces are expanded into exact names" {
  run as "$MINE" "rm -rf /private/tmp/mine-b.XYZ"; allowed_owned
  run as "$MINE" "rmdir /private/tmp/run3"; allowed_owned
  run as "$MINE" "rm -rf /private/tmp/run4"; not_allowed
  run as "$MINE" "rm -rf /private/tmp/mine-c.XYZ"; not_allowed
}
@test "owned: never the root of an area, even with nothing excluded below it" {
  run as "$MINE" "rm -rf $A/bare"; not_allowed
  run as "$MINE" "rm -rf $A/bare/sub"; allowed_owned
  run as "$MINE" "rm -rf $A/mine"; not_allowed
  run as "$MINE" "rm -rf ~/.claude/.scratchpad.d/topic"; not_allowed
}
@test "owned: a glob or a variable in the target is not an exact path" {
  run as "$MINE" "rm -rf $A/mine/pro*"; not_allowed
  run as "$MINE" 'rm -rf $D/probe'; not_allowed
}
@test "owned: two targets at once are not one exact path" {
  run as "$MINE" "rm -rf $A/mine/probe $A/mine/logs"; not_allowed
}
@test "owned: an excluded file, and a directory that would take it, stay" {
  run as "$MINE" "rm $A/mine/logs/redact.sh"; not_allowed
  run as "$MINE" "rm -rf $A/mine/logs"; not_allowed
}
@test "owned: a directory holding a .secrets is found on disk and stays" {
  run as "$MINE" "rm -rf $A/mine/vault"; not_allowed
}
@test "owned: a live page is never removed" {
  run as "$MINE" "rm ~/.claude/.scratchpad.d/topic/LIVE.md"; not_allowed
}
@test "owned: another session's area is not mine" {
  run as "$MINE" "rm -rf $A/theirs/x"; not_allowed
  run as 22222222-0000-0000-0000-000000000002 "rm -rf $A/theirs/x"; allowed_owned
}
@test "owned: an unknown session has no area" {
  run as 99999999-0000-0000-0000-000000000009 "rm -rf $A/mine/probe"; not_allowed
  run as "" "rm -rf $A/mine/probe"; not_allowed
}
@test "owned: cd anywhere and read-only commands around the removal keep the grant" {
  run as "$MINE" "cd / && rm $A/mine/probe && echo removed"; allowed_owned
  run as "$MINE" "rm -rf $A/mine/probe; ls $A/mine"; allowed_owned
  run as "$MINE" "cd $A/mine && rm -rf probe && test ! -e probe"; allowed_owned
}
@test "owned: any other command in the call leaves it to the usual rules" {
  run as "$MINE" "rm -rf $A/mine/probe && touch $A/mine/x"; not_allowed
  run as "$MINE" "rm -rf $A/mine/probe; bash -c true"; not_allowed
}
@test "owned: a substitution runs a command of its own, so it voids the grant" {
  run as "$MINE" 'rm -rf '"$A"'/mine/probe; echo $(true)'; not_allowed
}
@test "owned: a relative target after a cd must still resolve inside the area" {
  run as "$MINE" "cd $A && rm -rf theirs-not-mine"; not_allowed
}
@test "owned: one rm that does not qualify voids the grant for the whole call" {
  run as "$MINE" "rm -rf $A/mine/probe && rm /private/tmp/somewhere-unregistered"; not_allowed
}
@test "owned: a worktree of mine through git worktree remove, never with --force" {
  run as "$MINE" "git -C /Volumes/git-worktree-store/seedmatic/ndh.d/develop worktree remove /Volumes/git-worktree-store/seedmatic/ndh.d/fix/old"
  allowed_owned
  run as "$MINE" "git worktree remove --force /Volumes/git-worktree-store/seedmatic/ndh.d/fix/old"; not_allowed
  run as "$MINE" "rm -rf /Volumes/git-worktree-store/seedmatic/ndh.d/fix/old"; not_allowed
}
@test "owned: a denied command stays denied even in my area" {
  run as "$MINE" "rm -rf $A/mine/probe; cat ~/.ssh/id_ed25519"
  [ "$status" -eq 2 ]
}
@test "symlink: with a trailing slash rm empties the target, so it is never an owned removal" {
  run as "$MINE" "rm -rf $A/mine/link-vault/"; not_allowed
}
@test "symlink: without one, the link alone goes, even when it points at an excluded directory" {
  run as "$MINE" "rm $A/mine/link-vault"; allowed_owned
}
@test "symlink: a symlinked directory on the way may not lead out of the area" {
  run as "$MINE" "rm -rf $A/mine/hop/f"; not_allowed
}
@test "/tmp is refused with the /private/tmp form to write instead" {
  run as "$MINE" "rm -rf /tmp/mine-a.XYZ"
  [ "$status" -eq 2 ] && [[ "$output" == *"write /private/tmp/mine-a.XYZ"* ]]
}
@test "foreign: a NON-recursive rm in another session's area is denied, naming its owner" {
  run as "$MINE" "rm $A/theirs/x/file"
  [ "$status" -eq 2 ] && [[ "$output" == *"belongs to theirs"* ]]
}
@test "foreign: recursive too, and the area's root, existing or not" {
  run as "$MINE" "rm -rf $A/theirs/x"; [ "$status" -eq 2 ]
  run as "$MINE" "rm -rf $A/theirs"; [ "$status" -eq 2 ]
  run as "$MINE" "rm $A/theirs/does-not-exist"; [ "$status" -eq 2 ]
}
@test "foreign: under a global exclude, for every session" {
  run as "$MINE" "rm -rf $A/frozen/y"
  [ "$status" -eq 2 ]
  [[ "$output" == *"excluded for every session"* ]]
  run as "$MINE" "rm /Volumes/git-bare-store/seedmatic/x.git/HEAD"; [ "$status" -eq 2 ]
}
@test "foreign: an unknown session gets a deny on any engraved area" {
  run as 99999999-0000-0000-0000-000000000009 "rm $A/mine/probe"
  [ "$status" -eq 2 ] && [[ "$output" == *"belongs to mine"* ]]
}
@test "foreign: an unregistered path keeps the usual rules" {
  run as "$MINE" "rm /private/tmp/somewhere-unregistered"
  [ "$status" -eq 0 ] && not_allowed
}
@test "root: <p>/** never grants <p>, a bare <p> does, the exclude walk still applies below" {
  run as "$MINE" "rm -rf $A/probe-root"; allowed_owned
  touch "$A/probe-root/x/.secrets"
  run as "$MINE" "rm -rf $A/probe-root"; not_allowed
}
@test "owned: without a registry, nobody has an area" {
  rm "$T/hook/owned-dirs.json"
  run as "$MINE" "rm -rf $A/mine/probe"; not_allowed
}

# A cd the hook resolves is followed, $HOME included; one it cannot resolve loses the cwd, so a relative removal
# after it is refused rather than judged against the previous directory (security, 2026-10-18).
deny() { [ "$status" -eq 2 ] || { echo "expected deny, got status=$status output=$output"; return 1; }; }
@test "cd: ~ into another area, then a relative rm" {
  run as "$MINE" "cd ~/.claude/.scratchpad.d/their-topic && rm x.md"; deny
}
@test "cd: \$HOME, \${HOME} and \"\$HOME\" into another area, then a relative rm" {
  run as "$MINE" 'cd $HOME/.claude/.scratchpad.d/their-topic && rm x.md'; deny
  run as "$MINE" 'cd ${HOME}/.claude/.scratchpad.d/their-topic && rm x.md'; deny
  run as "$MINE" 'cd "$HOME/.claude/.scratchpad.d/their-topic" && rm x.md'; deny
  [[ "$output" == *"belongs to theirs"* ]]
}
@test "cd: \$HOME then a relative rm of the parent of another area" {
  run as "$MINE" 'cd $HOME/.claude/.scratchpad.d && rm -rf their-topic'; deny
}
@test "cd: an absolute rm through \$HOME into another area is denied, not asked" {
  run as "$MINE" 'rm -rf $HOME/.claude/.scratchpad.d/their-topic/x'; deny
  [[ "$output" == *"belongs to theirs"* ]]
}
@test "cd: an unresolvable target loses the cwd (a variable, a substitution, cd -, pushd, popd)" {
  run as "$MINE" "d=$A/theirs; cd \$d && rm x"; deny
  run as "$MINE" "cd \"\$(dirname $A/theirs/x)\" && rm x"; deny
  run as "$MINE" "cd - && rm x"; deny
  run as "$MINE" "pushd \$d; rm x"; deny
  run as "$MINE" "popd; rm -f x"; deny
  [[ "$output" == *"cannot resolve"* ]]
}
@test "cd: after an unresolvable cd, an absolute exact path of mine stays an owned removal" {
  run as "$MINE" "cd \$d && rm -rf $A/mine/probe"; allowed_owned
}
@test "cd: the resolved chains stay refused (/, .., a subshell, || exit, pushd)" {
  run as "$MINE" "cd / && rm -rf ${A#/}/theirs/x"; deny
  run as "$MINE" "cd $A/mine && cd .. && rm -rf theirs"; deny
  run as "$MINE" "(cd $A/theirs && rm x)"; deny
  run as "$MINE" "cd $A/theirs || exit; rm x"; deny
  run as "$MINE" "pushd $A/theirs; rm x"; deny
}
@test "cd: a relative rm in my own area after a resolved cd is unchanged" {
  run as "$MINE" "cd $A/mine && rm -rf probe"; allowed_owned
}
@test "cd: pushd's stack forms lose the cwd (no argument, +N, -N)" {
  run as "$MINE" "pushd $A/mine; pushd; rm x"; deny
  run as "$MINE" "pushd $A/mine; pushd +1; rm x"; deny
  run as "$MINE" "pushd $A/mine; pushd -1; rm x"; deny
  [[ "$output" == *"cannot resolve"* ]]
}
@test "cd: HOME assigned in the command, then ~, \$HOME or a bare cd, loses the cwd" {
  run as "$MINE" "HOME=$A/theirs; cd ~ && rm x"; deny
  run as "$MINE" "export HOME=$A/theirs; cd && rm x"; deny
  run as "$MINE" "HOME=$A/theirs cd \$HOME && rm x"; deny
  run as "$MINE" "declare HOME=$A/theirs; cd ~/ && rm x"; deny
  run as "$MINE" "unset HOME; cd && rm x"; deny
}
@test "cd: CDPATH assigned, then a relative cd, loses the cwd" {
  run as "$MINE" "CDPATH=$A; cd theirs && rm x"; deny
  run as "$MINE" "export CDPATH=$A; cd theirs && rm x"; deny
}
@test "cd: an absolute cd with CDPATH set is still followed" {
  run as "$MINE" "CDPATH=/elsewhere; cd $A/mine && rm -rf probe"; allowed_owned
}
