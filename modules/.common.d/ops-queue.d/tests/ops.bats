#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# The BUILT `ops`, on queues derived from fixtures (tests/package.nix), and the script on mutated queue files it must
# refuse. Nothing here reaches a machine: `ops` reads only its frozen queue.

setup() {
  : "where the keys-reconcile and ndh-ops stubs record what ops asked them (tests/package.nix)"
  export OPS_CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$OPS_CALLS"
}

# The built `ops` runs through `bash`: its `#!/usr/bin/env -S bash` line has no /usr/bin/env in the build sandbox.
ops() { # $1 = the built ops, then its arguments
  bash "$@"
}

# The substituted script with its queue pointed at a given file: the package's text, another queue.
ops_on() { # $1 = a queue.json
  sed "s#^queue=.*#queue=\"$1\"#" "$OPS_SH" >"$BATS_TEST_TMPDIR/ops"
  bash "$BATS_TEST_TMPDIR/ops" "${@:2}"
}

@test "an empty queue: « nothing to do », exit 0" {
  run --separate-stderr ops "$OPS_EMPTY" next
  [ "$status" -eq 0 ]
  [ "$output" = "nothing to do" ]
}

@test "keyring slots only: ops next has nothing to do" {
  run --separate-stderr ops "$OPS_KEYRING" next
  [ "$status" -eq 0 ]
  [ "$output" = "nothing to do" ]
}

@test "keyring slots are listed by ops queue as waiting for a declaration" {
  run --separate-stderr ops "$OPS_KEYRING" queue
  [ "$status" -eq 0 ]
  [[ $output == *"waiting for a declaration"* ]]
  [[ $output == *"host-mac@26-10-18 (recorded, born in the keyring)"* ]]
}

@test "generate: the machines in fleet-switch's order, the seat last" {
  run --separate-stderr ops "$OPS_GENERATE" next
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "next step: generate, in fleet-switch's order:" ]]
  g1=$(grep -n '• g1 ' <<<"$output" | cut -d: -f1)
  mac=$(grep -n '• mac ' <<<"$output" | cut -d: -f1)
  seat=$(grep -n '• seat ' <<<"$output" | cut -d: -f1)
  [ "$g1" -lt "$mac" ] && [ "$mac" -lt "$seat" ]
}

@test "generate: ops next measures (plan), and opens the window only when every machine is ready" {
  KR_PLAN_RC=0 run --separate-stderr ops "$OPS_GENERATE" next
  [ "$status" -eq 0 ]
  [ "$(cat "$OPS_CALLS")" = $'keys-reconcile plan\nndh-ops keys-reconcile window' ]
  : >"$OPS_CALLS"
  KR_PLAN_RC=4 run --separate-stderr ops "$OPS_GENERATE" next
  [ "$status" -eq 0 ]
  [ "$(cat "$OPS_CALLS")" = "keys-reconcile plan" ]
  [[ $output == *"the window waits"* ]]
}

@test "serve and an unmet condition run nothing" {
  run --separate-stderr ops "$OPS_SERVE" next
  [[ $output == *"for 🎛️"* ]]
  [ ! -s "$OPS_CALLS" ]
}

@test "generate: reachability is « not verified », never shown as met" {
  run --separate-stderr ops "$OPS_GENERATE" next
  [[ $output == *"? not verified: g1 reachable"* ]]
  [[ $output != *"✗ unmet"* ]]
}

@test "a head whose condition is unmet is refused, the condition named" {
  echo '{"head": [{"step": "serve", "key": "host-g1", "machine": "g1", "slot": "26-11-01", "checked": ["a condition"], "unchecked": [], "does": "servir"}], "blocked": [], "waiting": []}' >"$BATS_TEST_TMPDIR/q.json"
  run --separate-stderr ops_on "$BATS_TEST_TMPDIR/q.json" next
  [ "$status" -eq 0 ]
  [[ $output == *"✗ unmet: a condition"* ]]
  [[ $output == *"refused: a condition is unmet"* ]]
}

@test "mixed: the head is the earliest step; the later one is listed by ops queue, blocked" {
  run --separate-stderr ops "$OPS_MIXED" next
  [[ $output == *"next step: generate"* ]]
  [[ $output != *"• g1 "* ]]
  run --separate-stderr ops "$OPS_MIXED" queue
  [[ $output == *"then:"* ]]
  [[ $output == *"✗ unmet: the previous step is not done on the whole fleet"* ]]
}

@test "serve: host and sshfs keys alike" {
  run --separate-stderr ops "$OPS_SERVE" next
  [[ $output == *"next step: serve"* ]]
  [[ $output == *"• g2 — switch g2: it serves sshfs-g2@26-11-01"* ]]
  [[ $output == *"• mac — switch mac: it serves host-mac@26-11-01"* ]]
}

@test "ops never writes: the same output twice, and nothing created under an empty HOME" {
  export HOME="$BATS_TEST_TMPDIR/home" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/home/.cache"
  mkdir -p "$HOME"
  : "a plan that is not ready: ops measures and stops, so it writes nothing of its own"
  a=$(KR_PLAN_RC=4 ops "$OPS_GENERATE" next 2>/dev/null)
  b=$(KR_PLAN_RC=4 ops "$OPS_GENERATE" next 2>/dev/null)
  [ "$a" = "$b" ]
  [ -z "$(find "$HOME" -mindepth 1 2>/dev/null)" ]
}

@test "usage: no verb, an unknown verb, or extra arguments" {
  run --separate-stderr ops "$OPS_EMPTY"
  [ "$status" -eq 2 ]
  run --separate-stderr ops "$OPS_EMPTY" apply
  [ "$status" -eq 2 ]
  run --separate-stderr ops "$OPS_EMPTY" next now
  [ "$status" -eq 2 ]
}

# Mutants of the frozen queue: each must be refused, not read as « nothing to do ».
@test "mutant: a missing queue file is refused" {
  run --separate-stderr ops_on "$BATS_TEST_TMPDIR/absent.json" next
  [ "$status" -eq 1 ]
  [[ $stderr == *"unreadable"* ]]
}

@test "mutant: a queue without a head list is refused, not read as empty" {
  echo '{"blocked": [], "waiting": []}' >"$BATS_TEST_TMPDIR/q.json"
  run --separate-stderr ops_on "$BATS_TEST_TMPDIR/q.json" next
  [ "$status" -eq 1 ]
  [[ $stderr == *"malformed"* ]]
}

@test "mutant: a head that is not a list is refused" {
  echo '{"head": {}, "blocked": [], "waiting": []}' >"$BATS_TEST_TMPDIR/q.json"
  run --separate-stderr ops_on "$BATS_TEST_TMPDIR/q.json" next
  [ "$status" -eq 1 ]
}

@test "mutant: a queue that is not JSON is refused" {
  echo 'not json' >"$BATS_TEST_TMPDIR/q.json"
  run --separate-stderr ops_on "$BATS_TEST_TMPDIR/q.json" next
  [ "$status" -eq 1 ]
}
