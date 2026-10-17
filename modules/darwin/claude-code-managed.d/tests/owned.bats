#!/usr/bin/env bats
# The deletion areas: a copy of the hook beside a fixture owned-dirs.json, two sessions, real directories under the
# test's tmp dir for the on-disk exclude. Nothing here removes anything: the hook only answers.

setup() {
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/hook" "$T/state"
  cp "$BATS_TEST_DIRNAME/../deny-hook.py" "$BATS_TEST_DIRNAME/../verbs.json" "$T/hook/"
  export HOME=/Users/tester XDG_STATE_HOME="$T/state"
  A="$T/areas"
  mkdir -p "$A/mine/probe" "$A/mine/logs" "$A/mine/vault" "$A/theirs/x" "$A/bare/sub"
  touch "$A/mine/vault/.secrets" "$A/mine/logs/redact.sh"
  cat >"$T/hook/owned-dirs.json" <<EOF
{
  "pages_never_remove": ["~/.claude/.scratchpad.d/*/LIVE.md"],
  "global_exclude": ["~", "/Volumes/git-bare-store/**", "**/.secrets", "**/.secrets/**"],
  "sessions": {
    "mine": {
      "owned": ["$A/mine/**", "$A/bare/**", "~/.claude/.scratchpad.d/topic/**", "/private/tmp/mine-{a,b}.*", "/private/tmp/run{1..3}"],
      "worktrees": ["/Volumes/git-worktree-store/seedmatic/ndh.d/*/*"],
      "exclude": ["$A/mine/logs/redact.sh"],
      "conversations": ["11111111-0000-0000-0000-000000000001"]
    },
    "theirs": {
      "owned": ["$A/theirs/**"],
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

@test "owned: one exact path in my area is removed without a prompt, and audited" {
  run as "$MINE" "rm -rf $A/mine/probe"
  allowed_owned
  grep -q "mine removes $A/mine/probe ($A/mine/\*\*)" "$T/state/claude-deny-hook/log"
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
@test "owned: mixed with any other command, the call goes the usual way" {
  run as "$MINE" "rm -rf $A/mine/probe && ls"; not_allowed
  run as "$MINE" "cd / && rm -rf $A/mine/probe"; not_allowed
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
@test "owned: without a registry, nobody has an area" {
  rm "$T/hook/owned-dirs.json"
  run as "$MINE" "rm -rf $A/mine/probe"; not_allowed
}
