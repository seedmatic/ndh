#!/usr/bin/env bats
# The session hooks against a throwaway layout: a fake HOME, a repo, its memory worktree on the
# `memory` branch, and a hand-made transcript. Nothing here touches the real ~/.claude.

setup() {
  H="$BATS_TEST_DIRNAME/.."
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME/.claude"
  git config --global user.name tester
  git config --global user.email tester@example.invalid
  git config --global init.defaultBranch develop

  REPO="$T/repo"
  git init -q "$REPO"
  git -C "$REPO" commit -q --allow-empty -m init
  git -C "$REPO" branch memory
  MEM="$T/repo.d/memory"
  git -C "$REPO" worktree add -q "$MEM" memory
  printf 'seed\n' >"$MEM/MEMORY.md"
  git -C "$MEM" add MEMORY.md
  git -C "$MEM" commit -q -m seed
  printf '{"autoMemoryDirectory": "%s"}\n' "$MEM" >"$HOME/.claude/settings.json"
  TR="$T/session.jsonl"
  : >"$TR"
}

# A transcript line in Claude Code's shape: one assistant turn with one tool_use.
wrote() { # $1 = tool, $2 = path
  jq -cn --arg t "$1" --arg p "$2" \
    '{type: "assistant", message: {content: [{type: "tool_use", name: $t, input: {file_path: $p}}]}}' >>"$TR"
}

hook() { # $1 = script, stdin payload built from the session
  (cd "$REPO" && jq -cn --arg tr "$TR" '{session_id: "abcd1234-0000", transcript_path: $tr}' | bash "$H/$1")
}

commits() { git -C "$MEM" rev-list --count HEAD; }

# --- memory-guard ---
@test "guard: silent when memory is wired and clean" {
  run hook memory-guard.sh
  [ "$status" -eq 0 ] && [ -z "$output" ]
}
@test "guard: silent when no level redirects memory" {
  rm "$HOME/.claude/settings.json"
  run hook memory-guard.sh
  [ "$status" -eq 0 ] && [ -z "$output" ]
}
@test "guard: a directory off the memory branch is reported" {
  git -C "$MEM" switch -q -c elsewhere
  run hook memory-guard.sh
  [[ "$output" == *"not a worktree of the 'memory' branch"* ]]
}
@test "guard: a missing directory is reported" {
  printf '{"autoMemoryDirectory": "%s/nowhere"}\n' "$T" >"$HOME/.claude/settings.json"
  run hook memory-guard.sh
  [[ "$output" == *"does not exist"* ]]
}
@test "guard: the local level wins over the user level" {
  mkdir -p "$REPO/.claude"
  printf '{"autoMemoryDirectory": "%s/nowhere"}\n' "$T" >"$REPO/.claude/settings.local.json"
  run hook memory-guard.sh
  [[ "$output" == *"$T/nowhere"* ]]
}
@test "guard: a dirty memory worktree is reported" {
  printf 'x\n' >"$MEM/new.md"
  run hook memory-guard.sh
  [[ "$output" == *"1 uncommitted file(s)"* ]]
}

# --- memory-commit (operator's decision: this session's own Write/Edit only) ---
@test "commit: the session's Write is committed, and only it" {
  printf 'mine\n' >"$MEM/mine.md"
  printf 'theirs\n' >"$MEM/theirs.md"
  wrote Write "$MEM/mine.md"
  before="$(commits)"
  run hook memory-commit.sh
  [ "$(commits)" -eq $((before + 1)) ]
  git -C "$MEM" show --name-only --format= HEAD | grep -qx mine.md
  ! git -C "$MEM" show --name-only --format= HEAD | grep -q theirs.md
  [[ "$(git -C "$MEM" status --porcelain)" == "?? theirs.md" ]]
  [[ "$output" == *"push FAILED"* ]] # no remote here: reported, not fatal
}
@test "commit: an Edit of a tracked file is committed" {
  printf 'more\n' >>"$MEM/MEMORY.md"
  wrote Edit "$MEM/MEMORY.md"
  run hook memory-commit.sh
  [ -z "$(git -C "$MEM" status --porcelain)" ]
}
@test "commit: a file written by Bash is NOT committed, and the guard reports it" {
  printf 'bash wrote me\n' >"$MEM/by-bash.md"
  before="$(commits)"
  run hook memory-commit.sh
  [ "$(commits)" -eq "$before" ]
  run hook memory-guard.sh
  [[ "$output" == *"1 uncommitted file(s)"* ]]
}
@test "commit: a Write outside the memory directory is ignored" {
  printf 'code\n' >"$REPO/code.txt"
  wrote Write "$REPO/code.txt"
  before="$(commits)"
  run hook memory-commit.sh
  [ "$(commits)" -eq "$before" ] && [ -z "$output" ]
}
@test "commit: another session's STAGED file stays out of the commit" {
  printf 'staged elsewhere\n' >"$MEM/staged.md"
  git -C "$MEM" add staged.md
  printf 'mine\n' >"$MEM/mine.md"
  wrote Write "$MEM/mine.md"
  run hook memory-commit.sh
  ! git -C "$MEM" show --name-only --format= HEAD | grep -q staged.md
  [[ "$(git -C "$MEM" status --porcelain)" == "A  staged.md" ]]
}
@test "commit: nothing written, nothing committed, nothing said" {
  before="$(commits)"
  run hook memory-commit.sh
  [ "$(commits)" -eq "$before" ] && [ -z "$output" ]
}

# --- checkpoints, under <repo>/.scratchpad.d/checkpoints ---
@test "checkpoint-write consumes the draft into a checkpoint" {
  mkdir -p "$REPO/.scratchpad.d/checkpoints"
  printf '# Session Context\nthe draft\n' >"$REPO/.scratchpad.d/checkpoints/checkpoint-draft-abcd1234-0000.md"
  run hook checkpoint-write.sh
  [ ! -e "$REPO/.scratchpad.d/checkpoints/checkpoint-draft-abcd1234-0000.md" ]
  grep -q 'the draft' "$REPO"/.scratchpad.d/checkpoints/checkpoint-abcd1234-0000-*.md
  [[ "$output" == *".scratchpad.d/checkpoints/checkpoint-abcd1234-0000-"* ]]
}
@test "checkpoint-write creates its directory" {
  run hook checkpoint-write.sh
  ls "$REPO"/.scratchpad.d/checkpoints/checkpoint-abcd1234-0000-*.md
}
@test "session-start-reminder finds the draft under .scratchpad.d" {
  mkdir -p "$REPO/.scratchpad.d/checkpoints"
  : >"$REPO/.scratchpad.d/checkpoints/checkpoint-draft-abcd1234-0000.md"
  run hook session-start-reminder.sh
  [ "$status" -eq 0 ] && [ -z "$output" ]
}
@test "checkpoint-gc prunes an orphan session's checkpoints" {
  mkdir -p "$REPO/.scratchpad.d/checkpoints"
  : >"$REPO/.scratchpad.d/checkpoints/checkpoint-deadbeef-0000-20261007-120000.md"
  run hook checkpoint-gc.sh
  [ ! -e "$REPO/.scratchpad.d/checkpoints/checkpoint-deadbeef-0000-20261007-120000.md" ]
  [[ "$output" == *"1 orphaned"* ]]
}
