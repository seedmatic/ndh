#!/usr/bin/env bats
# ndh-claude-wake against a fixture registry and a recording `open`: nothing is opened, no VS Code is needed.

setup() {
  D="$BATS_TEST_DIRNAME/.."
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" XDG_STATE_HOME="$T/state"
  mkdir -p "$HOME" "$T/bin"
  printf '#!%s\nprintf "%%s\\n" "open $*" >>"%s/calls"\n' "$BASH" "$T" >"$T/bin/open"
  chmod +x "$T/bin/open"
  export PATH="$T/bin:$PATH"
  cat >"$T/registry.json" <<'EOF'
{"sessions": {
  "develop": {"conversations": ["f45de9ce-1198-48b5-aa6b-3da49f833ea9"], "workspace": "/Volumes/git-worktree-store/seedmatic/rke2lab.d/develop"},
  "develop-claude": {"conversations": ["00000000-0000-0000-0000-000000000001", "af0dc1e5-609f-4ce0-8ab5-76a1c31bd7b0"], "workspace": "/Volumes/git-worktree-store/seedmatic/rke2lab.d/develop"},
  "develop-keyhole": {"conversations": ["5e1b8474-c12c-41a0-b59f-7d872501342e"], "workspace": "/Volumes/git-worktree-store/nxmatic/keyhole.d/main"},
  "develop-nows": {"conversations": ["11111111-2222-3333-4444-555555555555"]},
  "develop-badid": {"conversations": ["not-an-id"], "workspace": "/Volumes/git-worktree-store/seedmatic/ndh.d/develop"}
}}
EOF
  { printf 'registry=%q\nbundle=com.example.Code\nscheme=code-test\nsettle=0\n' "$T/registry.json"; cat "$D/ndh-claude-wake.sh"; } >"$T/wake"
}

wake() { bash "$T/wake" "$@"; }

@test "every engraved session is opened by its documented link, its workspace first" {
  run wake
  [ "$status" -eq 0 ]
  grep -qx "open code-test://anthropic.claude-code/open?session=f45de9ce-1198-48b5-aa6b-3da49f833ea9" "$T/calls"
  grep -qx "open code-test://anthropic.claude-code/open?session=5e1b8474-c12c-41a0-b59f-7d872501342e" "$T/calls"
  [ "$(grep -n 'open -b com.example.Code /Volumes/git-worktree-store/nxmatic/keyhole.d/main' "$T/calls" | cut -d: -f1)" -lt \
    "$(grep -n 'session=5e1b8474' "$T/calls" | cut -d: -f1)" ]
}
@test "a workspace shared by several sessions is opened once" {
  run wake
  [ "$(grep -c 'open -b com.example.Code /Volumes/git-worktree-store/seedmatic/rke2lab.d/develop$' "$T/calls")" -eq 1 ]
}
@test "only the current (last) conversation of a name is opened" {
  run wake
  grep -q "session=af0dc1e5-609f-4ce0-8ab5-76a1c31bd7b0" "$T/calls"
  [ -z "$(grep "session=00000000-0000-0000-0000-000000000001" "$T/calls")" ]
}
@test "a session with no engraved workspace, or no valid id, is skipped and logged" {
  run wake
  [[ "$output" == *"develop-nows: no workspace engraved, skipped"* ]]
  [[ "$output" == *"develop-badid: no valid conversation id engraved, skipped"* ]]
  [ -z "$(grep "11111111-2222\|not-an-id" "$T/calls")" ]
  grep -q "develop-nows: skipped, no workspace engraved" "$T/state/ndh-claude-wake/log"
}
@test "--only wakes the named session alone, and refuses a name that is not engraved" {
  run wake --only develop-keyhole
  [ "$status" -eq 0 ]
  [ "$(grep -c 'session=' "$T/calls")" -eq 1 ]
  run wake --only develop-ghost
  [ "$status" -eq 3 ] && [[ "$output" == *"develop-ghost is not engraved"* ]]
}
@test "a dry run opens nothing, and says what it would open" {
  run wake --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ open code-test://anthropic.claude-code/open?session=f45de9ce"* ]]
  [ ! -e "$T/calls" ]
}
@test "no registry, or an empty one, is refused" {
  rm "$T/registry.json"
  run wake
  [ "$status" -eq 3 ]
  [[ "$output" == *"no installed registry"* ]]
  printf '{"sessions": {}}\n' >"$T/registry.json"
  run wake; [ "$status" -eq 3 ] && [[ "$output" == *"engraves no session"* ]]
}
@test "it never runs claude itself" {
  # Code only: the comments name `claude` to say why it is never run.
  [ -z "$(grep -v '^[[:space:]]*#' "$D/ndh-claude-wake.sh" | grep -E '(^|[^-[:alnum:]_.])claude([[:space:]]|$)')" ]
  run wake
  [ -z "$(grep -v '^open ' "$T/calls")" ]
}
