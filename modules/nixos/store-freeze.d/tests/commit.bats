#!/usr/bin/env bats
# ndh-store-commit, the real script under errexit (as writeShellApplication runs it), with ONLY its own tools on the
# path: stage 2 makes the stack this boot chose the current one, sets a refused next one aside, drops a satisfied
# freeze request, and empties the trash. A request without a snapshot must not stop it: yq exits 1 on `// empty`
# over a null where jq exited 0.

setup() {
  T=$BATS_TEST_TMPDIR
  export STACK_DIR="$T/stack" RW_MOUNT="$T/rw" RUN_DIR="$T/run"
  mkdir -p "$STACK_DIR" "$RW_MOUNT/trash/old-upper" "$RUN_DIR"
  : >"$RW_MOUNT/trash/old-upper/a-file"
  layers='[{"dataset": "tank/u", "snapshot": "ndh-store-20261022T100000Z", "guid": "1"}]'
  printf '{"version": "1", "layers": %s, "over": []}\n' "$layers" >"$STACK_DIR/next.json"
  printf '{"version": "1", "layers": [], "over": []}\n' >"$STACK_DIR/current.json"
  printf '{"manifest": "next", "frozen": []}\n' >"$RUN_DIR/store-stack.json"
}

commit() {
  # bash by its own path, as writeShellApplication's shebang names it: the PATH holds the script's tools and no more.
  run env -i PATH="${TOOLS_PATH:?}" STACK_DIR="$STACK_DIR" RW_MOUNT="$RW_MOUNT" RUN_DIR="$RUN_DIR" \
    "$BASH" -euo pipefail "$BATS_TEST_DIRNAME/../commit.sh"
}

@test "the chosen next stack becomes the current one, the old current the previous one" {
  commit
  [ "$status" -eq 0 ]
  [ ! -e "$STACK_DIR/next.json" ]
  grep -q ndh-store-20261022T100000Z "$STACK_DIR/current.json"
  [ -e "$STACK_DIR/previous.json" ]
  [ ! -e "$RW_MOUNT/trash/old-upper" ]
}

@test "a freeze request the new current stack holds is dropped" {
  printf '{"snapshot": "ndh-store-20261022T100000Z"}\n' >"$STACK_DIR/request.json"
  commit
  [ "$status" -eq 0 ]
  [ ! -e "$STACK_DIR/request.json" ]
  # yq without -o warns on stderr at every call, and `// empty` is a syntax error in yq-go: neither may reach the log.
  [[ $output != *WARN* ]]
  [[ $output != *lexer* ]]
}

@test "a freeze request the stack does not hold is kept" {
  printf '{"snapshot": "ndh-store-20261022T999999Z"}\n' >"$STACK_DIR/request.json"
  commit
  [ "$status" -eq 0 ]
  [ -e "$STACK_DIR/request.json" ]
}

@test "a request with a null snapshot neither stops the commit nor is dropped, and the trash is emptied" {
  printf '{"snapshot": null}\n' >"$STACK_DIR/request.json"
  commit
  [ "$status" -eq 0 ]
  [ -e "$STACK_DIR/request.json" ]
  [ ! -e "$RW_MOUNT/trash/old-upper" ]
}

@test "a refused next manifest is set aside, the current one kept" {
  printf '{"manifest": "current", "frozen": []}\n' >"$RUN_DIR/store-stack.json"
  commit
  [ "$status" -eq 0 ]
  [ ! -e "$STACK_DIR/next.json" ]
  ls "$STACK_DIR"/refused/next-*.json >/dev/null
  grep -q '"layers": \[\]' "$STACK_DIR/current.json"
}

@test "a degraded boot commits nothing" {
  : >"$RUN_DIR/store-degraded"
  commit
  [ "$status" -eq 0 ]
  [ -e "$STACK_DIR/next.json" ]
  [ -e "$RW_MOUNT/trash/old-upper" ]
}
