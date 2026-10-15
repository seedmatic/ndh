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
@test "guard: any branch name is fine — none is assumed" {
  git -C "$MEM" switch -q -c notes-of-some-repo
  run hook memory-guard.sh
  [ "$status" -eq 0 ] && [ -z "$output" ]
}
@test "guard: a directory outside any worktree is reported" {
  mkdir -p "$T/loose"
  printf '{"autoMemoryDirectory": "%s/loose"}\n' "$T" >"$HOME/.claude/settings.json"
  run hook memory-guard.sh
  [[ "$output" == *"not inside a git worktree"* ]]
}
@test "guard: a detached HEAD is reported" {
  git -C "$MEM" switch -q --detach
  run hook memory-guard.sh
  [[ "$output" == *"detached HEAD"* ]]
}
@test "guard: a subdirectory reports its own dirt, not another subdirectory's" {
  mkdir -p "$MEM/rke2lab" "$MEM/nnh"
  printf '{"autoMemoryDirectory": "%s/rke2lab"}\n' "$MEM" >"$HOME/.claude/settings.json"
  printf 'theirs\n' >"$MEM/nnh/fact.md"
  run hook memory-guard.sh
  [ -z "$output" ]
  printf 'mine\n' >"$MEM/rke2lab/fact.md"
  run hook memory-guard.sh
  [[ "$output" == *"1 uncommitted file(s)"* ]]
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
  [ -z "$(git -C "$MEM" show --name-only --format= HEAD | grep theirs.md)" ]
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
  [ -z "$(git -C "$MEM" show --name-only --format= HEAD | grep staged.md)" ]
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

# --- two projects, two memories: everything comes from the autoMemoryDirectory in force ---
@test "commit: a project-level autoMemoryDirectory takes the session's write, the user one does not" {
  OTHER="$T/other.d/memory"
  git init -q "$OTHER"
  git -C "$OTHER" commit -q --allow-empty -m init
  mkdir -p "$REPO/.claude"
  printf '{"autoMemoryDirectory": "%s"}\n' "$OTHER" >"$REPO/.claude/settings.json"
  printf 'project memory\n' >"$OTHER/fact.md"
  printf 'user memory\n' >"$MEM/fact.md"
  wrote Write "$OTHER/fact.md"
  wrote Write "$MEM/fact.md"
  user_before="$(commits)"
  run hook memory-commit.sh
  git -C "$OTHER" show --name-only --format= HEAD | grep -qx fact.md
  [ "$(commits)" -eq "$user_before" ]
  [[ "$(git -C "$MEM" status --porcelain)" == "?? fact.md" ]]
}
@test "commit: in a subdirectory memory, the session's file is committed, another subdirectory's dirt is not" {
  mkdir -p "$MEM/rke2lab" "$MEM/nnh"
  printf '{"autoMemoryDirectory": "%s/rke2lab"}\n' "$MEM" >"$HOME/.claude/settings.json"
  printf 'mine\n' >"$MEM/rke2lab/fact.md"
  printf 'theirs\n' >"$MEM/nnh/fact.md"
  wrote Write "$MEM/rke2lab/fact.md"
  before="$(commits)"
  run hook memory-commit.sh
  [ "$(commits)" -eq $((before + 1)) ]
  [[ "$(git -C "$MEM" show --name-only --format= HEAD)" == "rke2lab/fact.md" ]]
  [[ "$(git -C "$MEM" status --porcelain)" == "?? nnh/" ]]
}

# --- live-page ---
start() { # $1 = source, $2 = the session's current title (empty: never renamed)
  jq -cn --arg s "$1" --arg t "${2:-}" \
    '{session_id: "abcd1234-0000", source: $s, cwd: "/w", transcript_path: "/t.jsonl"} + (if $t == "" then {} else {session_title: $t} end)' |
    CLAUDE_SCRATCHPAD="$T" bash "$H/live-page.sh"
}

live() {
  mkdir -p "$T/integration-sow"
  printf '# Intégration — LIVE\n> tenu par develop-ab\n## 0. En figures\nFIGBODY\n## 1. Ce qui t%sattend\nT1\n## 2. En cours\nnoise\n## 4. Arbre des sessions\ntree\n' "'" >"$T/integration-sow/LIVE.md"
}

@test "live: every start is registered, whatever its source" {
  live
  start startup >/dev/null
  start compact >/dev/null
  [ "$(wc -l <"$T/integration-sow/sessions.jsonl")" -eq 2 ]
  [[ "$(jq -r .source "$T/integration-sow/sessions.jsonl" | tr '\n' ' ')" == "startup compact " ]]
}

@test "live: a fresh start receives the header, section 1 and the tree, nothing else" {
  live
  run start startup
  c="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
  [[ "$c" == *"tenu par develop-ab"* && "$c" == *T1* && "$c" == *tree* ]]
  [[ "$c" != *FIGBODY* && "$c" != *noise* ]]
  [[ "$c" == *"conversation is abcd1234-0000"* ]]
}

@test "live: a compaction is registered but injects nothing" {
  live
  run start compact
  [ -z "$output" ]
}

@test "live: a missing page is said, and the start is still registered" {
  run start startup
  [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"does not exist"* ]]
  [ -f "$T/integration-sow/sessions.jsonl" ]
}

chantier() { # a chantier page that claims the test conversation
  mkdir -p "$T/chantierx"
  printf '# Chantier X — LIVE\n> conversation: abcd1234-0000\n> title: chantier-x\n## 1. Etat\nok\n' >"$T/chantierx/LIVE.md"
}

@test "live: a resume gets its chantier's title back, and a short reminder" {
  live
  chantier
  run start resume
  [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.sessionTitle)" == chantier-x ]]
  [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"You are the chantierx session"* ]]
  [[ "$(tail -1 "$T/integration-sow/sessions.jsonl" | jq -r '.chantier + "/" + .title')" == chantierx/chantier-x ]]
}

@test "live: a title the operator set wins over the declared one" {
  live
  chantier
  run start resume operator-choice
  [[ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.sessionTitle // "none"')" == none ]]
  [[ "$(tail -1 "$T/integration-sow/sessions.jsonl" | jq -r .title)" == operator-choice ]]
}

@test "live: a session no page claims is told how to declare itself" {
  live
  run start resume
  [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"> conversation: abcd1234-0000"* ]]
  [[ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.sessionTitle // "none"')" == none ]]
}

# --- leak-guard ---
# One case per line of leak-guard-cases.tsv: the verdict, a tab, the command as a session would type it.
@test "leak-guard: every case gets its verdict" {
  local want cmd got bad=""
  while IFS=$'\t' read -r want cmd; do
    got="$(jq -cn --arg c "$cmd" '{tool_input: {command: $c}}' | bash "$H/leak-guard.sh" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')"
    got="${got:-allow}"
    [[ "$got" == "${want,,}" ]] || bad+="  want $want, got $got: $cmd"$'\n'
  done <"$BATS_TEST_DIRNAME/leak-guard-cases.tsv"
  [[ -z "$bad" ]] || { printf '%s' "$bad"; false; }
}

# --- sops-git-env ---

# The sops drivers come from an INCLUDED file, as the real git-sops-diff is; their commands
# fail, so a run that still used them would show it.
sops_drivers() {
  printf '[filter "sops-yaml"]\n\tclean = false\n\tsmudge = false\n\trequired = true\n[diff "sops-yaml"]\n\ttextconv = false\n[filter "sops-json"]\n\tclean = false\n\tsmudge = false\n\trequired = true\n[diff "sops-json"]\n\ttextconv = false\n' >"$T/sops-include"
  git config --global include.path "$T/sops-include"
}

@test "sops-git-env: no env file, nothing written" {
  sops_drivers
  run env -u CLAUDE_ENV_FILE bash "$H/sops-git-env.sh" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sops-git-env: every included sops driver becomes cat, the identity stays" {
  sops_drivers
  export CLAUDE_ENV_FILE="$T/env"
  bash "$H/sops-git-env.sh" </dev/null
  run bash -c '. "$CLAUDE_ENV_FILE"; echo "$GIT_CONFIG_COUNT $(git config filter.sops-yaml.smudge) $(git config filter.sops-yaml.required) $(git config diff.sops-json.textconv) $(git config user.name)"; git config filter.sops-json.clean'
  [ "${lines[0]}" = "8 cat true cat tester" ]
  [[ "${lines[1]}" == *"/sops-clean-guard.sh %f" ]]
}

@test "sops-git-env: an existing GIT_CONFIG_COUNT is kept, a second read adds nothing" {
  sops_drivers
  export CLAUDE_ENV_FILE="$T/env"
  bash "$H/sops-git-env.sh" </dev/null
  run bash -c 'export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=input; . "$CLAUDE_ENV_FILE"; . "$CLAUDE_ENV_FILE"; echo "$GIT_CONFIG_COUNT $(git config core.autocrlf) $(git config diff.sops-yaml.textconv)"'
  [ "$output" = "9 input cat" ]
}

@test "sops-git-env: a sops file checks out and diffs as the envelope on disk" {
  sops_drivers
  export CLAUDE_ENV_FILE="$T/env"
  bash "$H/sops-git-env.sh" </dev/null
  R="$T/sopsrepo"
  git init -q "$R"
  printf '*.yaml filter=sops-yaml diff=sops-yaml\n' >"$R/.gitattributes"
  run bash -c '. "$CLAUDE_ENV_FILE"; cd "'"$R"'" && printf "a: ENC[x]\nsops:\n  v: 1\n" >s.yaml && git add .gitattributes s.yaml && git commit -qm one && printf "a: ENC[y]\nsops:\n  v: 1\n" >s.yaml && git diff s.yaml | grep -c "ENC\[y\]" && rm s.yaml && git checkout -- s.yaml && head -1 s.yaml'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1" ]
  [ "${lines[1]}" = "a: ENC[x]" ]
}

@test "sops-git-env: a sops file in the clear on disk is refused at git add" {
  sops_drivers
  export CLAUDE_ENV_FILE="$T/env"
  bash "$H/sops-git-env.sh" </dev/null
  R="$T/clearrepo"
  git init -q "$R"
  printf '*.yaml filter=sops-yaml diff=sops-yaml\n' >"$R/.gitattributes"
  printf 'a: dummy-clear\n' >"$R/s.yaml"
  run bash -c '. "$CLAUDE_ENV_FILE"; cd "'"$R"'" && git add s.yaml'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a sops envelope"* ]]
  [[ "$output" != *"dummy-clear"* ]]
}

@test "sops-git-env: the clean guard holds the content in memory only" {
  # A refused content is the clear text. bash backs a large here-string with a temporary file it
  # unlinks at once — no listing ever sees it, and it falls back to /tmp when TMPDIR is unwritable —
  # so the property is checked on the script itself: no here-string, no pipe into a reader.
  # Not `! grep`: bats ignores a negated command's status.
  [ -z "$(grep -nE '<<<|\|[[:space:]]*(grep|sed|awk)' "$H/sops-clean-guard.sh")" ]
  { printf 'a: ENC[x]\nsops:\n  v: 1\n'; head -c 200000 /dev/zero | tr '\0' 'a'; } >"$T/big.yaml"
  run bash -c 'bash "$1" s.yaml <"$2" | wc -c' _ "$H/sops-clean-guard.sh" "$T/big.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -eq "$(wc -c <"$T/big.yaml")" ]
}

@test "sops-git-env: the clean guard passes yaml, json and dotenv envelopes unchanged" {
  for e in $'a: ENC[x]\nsops:\n  v: 1\n' $'{"a": "ENC[x]", "sops": {"v": 1}}\n' $'A=ENC[x]\nsops_version=3\n'; do
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$e" "$H/sops-clean-guard.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "${e%$'\n'}" ]
  done
}

@test "sops-git-env: drivers in the XDG config are found beside a ~/.gitconfig" {
  unset GIT_CONFIG_GLOBAL
  mkdir -p "$HOME/.config/git"
  printf '[user]\n\tname = tester\n' >"$HOME/.gitconfig"
  printf '[filter "sops-yaml"]\n\tsmudge = false\n[diff "sops-yaml"]\n\ttextconv = false\n' >"$HOME/.config/git/sops"
  printf '[include]\n\tpath = sops\n' >"$HOME/.config/git/config"
  export CLAUDE_ENV_FILE="$T/env"
  run bash "$H/sops-git-env.sh" </dev/null
  [ -z "$output" ]
  run bash -c '. "$CLAUDE_ENV_FILE"; git -C / config filter.sops-yaml.smudge; git -C / config diff.sops-yaml.textconv'
  [ "${lines[0]}" = "cat" ]
  [ "${lines[1]}" = "cat" ]
}

@test "sops-git-env: the file reads the same under zsh" {
  command -v zsh >/dev/null || skip "no zsh"
  sops_drivers
  export CLAUDE_ENV_FILE="$T/env"
  bash "$H/sops-git-env.sh" </dev/null
  run zsh -c '. "$CLAUDE_ENV_FILE"; echo "$GIT_CONFIG_COUNT $(git config filter.sops-yaml.smudge)"'
  [ "$output" = "8 cat" ]
}

@test "sops-git-env: without sops drivers, nothing is written" {
  export CLAUDE_ENV_FILE="$T/env"
  bash "$H/sops-git-env.sh" </dev/null
  [ ! -s "$CLAUDE_ENV_FILE" ]
}

# --- sops-filter-check: a flake repository naming a sops filter is announced at session start ---

# A repository with (or without) a flake, one sops-shaped file in the clear and one envelope. No sops
# driver is defined: check-attr reports the ATTRIBUTE, which is the question, whatever the driver.
filter_repo() { # $1 = with-flake | no-flake
  R="$T/fr"; mkdir -p "$R"; git -C "$R" init -q
  [ "$1" = with-flake ] && echo '{ outputs = _: { }; }' >"$R/flake.nix"
  printf 'token: in-the-clear\n' >"$R/secret.yaml"
  printf 'data: ENC[x]\nsops:\n  mac: ENC[y]\n' >"$R/sealed.yaml"
  git -C "$R" add -A && git -C "$R" commit -qm init
}
check() { printf '{"cwd":"%s"}' "$1" | bash "$H/sops-filter-check.sh"; }

@test "sops-filter-check: a committed filter= in a flake repo is announced, the clear file marked" {
  filter_repo with-flake
  printf '*.yaml filter=sops-yaml\n' >"$R/.gitattributes"; git -C "$R" add .gitattributes; git -C "$R" commit -qm attrs
  run check "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"systemMessage"'*'secret.yaml (IN THE CLEAR ON DISK)'* ]]
  [[ "$output" == *'sealed.yaml'* && "$output" != *'sealed.yaml (IN THE CLEAR'* ]]
}

@test "sops-filter-check: .git/info/attributes counts too (no commit at all)" {
  filter_repo with-flake
  printf 'secret.yaml filter=sops-yaml\n' >"$R/.git/info/attributes"
  run check "$R"
  [[ "$output" == *'secret.yaml (IN THE CLEAR ON DISK)'* ]]
}

@test "sops-filter-check: an UNCOMMITTED .gitattributes in the worktree counts" {
  filter_repo with-flake
  printf 'secret.yaml filter=sops-yaml diff=sops-yaml\n' >"$R/.gitattributes"
  run check "$R"
  [[ "$output" == *'secret.yaml'* ]]
}

@test "sops-filter-check: a flake repo with no filter= is silent" {
  filter_repo with-flake
  printf '*.yaml diff=sops-yaml\n' >"$R/.gitattributes"; git -C "$R" add .gitattributes; git -C "$R" commit -qm diff-only
  run check "$R"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "sops-filter-check: a repo without a flake may name filters, silent" {
  filter_repo no-flake
  printf '*.yaml filter=sops-yaml\n' >"$R/.gitattributes"; git -C "$R" add .gitattributes; git -C "$R" commit -qm attrs
  run check "$R"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "sops-filter-check: outside a repository, silent" {
  mkdir -p "$T/plain"
  run check "$T/plain"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}
