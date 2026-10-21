#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# The BUILT `ops`, on queues derived from fixtures (tests/package.nix), and the script on mutated queue files it must
# refuse. Nothing here reaches a machine: `ops` reads only its frozen queue.

# The built `ops` runs through `bash`: its `#!/usr/bin/env -S bash` line has no /usr/bin/env in the build sandbox.
ops() { # $1 = the built ops, then its arguments
  bash "$@"
}

# The substituted script with its queue pointed at a given file: the package's text, another queue.
ops_on() { # $1 = a queue.json
  sed "s#^queue=.*#queue=\"$1\"#" "$OPS_SH" >"$BATS_TEST_TMPDIR/ops"
  bash "$BATS_TEST_TMPDIR/ops" "${@:2}"
}

@test "an empty queue: « rien à faire », exit 0" {
  run --separate-stderr ops "$OPS_EMPTY" next
  [ "$status" -eq 0 ]
  [ "$output" = "rien à faire" ]
}

@test "keyring slots only: ops next has nothing to do" {
  run --separate-stderr ops "$OPS_KEYRING" next
  [ "$status" -eq 0 ]
  [ "$output" = "rien à faire" ]
}

@test "keyring slots are listed by ops queue as waiting for a declaration" {
  run --separate-stderr ops "$OPS_KEYRING" queue
  [ "$status" -eq 0 ]
  [[ $output == *"en attente d'une déclaration"* ]]
  [[ $output == *"host-mac@26-10-18 (recorded, née dans le trousseau)"* ]]
}

@test "generate: the machines in fleet-switch's order, the seat last" {
  run --separate-stderr ops "$OPS_GENERATE" next
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "prochain pas : generate, dans l'ordre de fleet-switch :" ]]
  g1=$(grep -n '• g1 ' <<<"$output" | cut -d: -f1)
  mac=$(grep -n '• mac ' <<<"$output" | cut -d: -f1)
  seat=$(grep -n '• seat ' <<<"$output" | cut -d: -f1)
  [ "$g1" -lt "$mac" ] && [ "$mac" -lt "$seat" ]
}

@test "generate: reachability is « non vérifié », never shown as met" {
  run --separate-stderr ops "$OPS_GENERATE" next
  [[ $output == *"? non vérifié : g1 joignable"* ]]
  [[ $output != *"✗ non remplie"* ]]
}

@test "a step that cannot run yet is refused, the unmet condition named" {
  run --separate-stderr ops "$OPS_WINDOW" next
  [ "$status" -eq 0 ]
  [[ $output == *"✗ non remplie : le pas « ouvrir la fenêtre » arrive avec K4 (keys-reconcile)"* ]]
  [[ $output == *"refusé : une condition n'est pas remplie"* ]]
}

@test "mixed: the head is the earliest step; the later one is listed by ops queue, blocked" {
  run --separate-stderr ops "$OPS_MIXED" next
  [[ $output == *"prochain pas : generate"* ]]
  [[ $output != *"• g1 "* ]]
  run --separate-stderr ops "$OPS_MIXED" queue
  [[ $output == *"ensuite :"* ]]
  [[ $output == *"✗ non remplie : le pas précédent n'est pas fini sur toute la flotte"* ]]
}

@test "serve: host and sshfs keys alike" {
  run --separate-stderr ops "$OPS_SERVE" next
  [[ $output == *"prochain pas : serve"* ]]
  [[ $output == *"• g2 — basculer g2 : il sert sshfs-g2@26-11-01"* ]]
  [[ $output == *"• mac — basculer mac : il sert host-mac@26-11-01"* ]]
}

@test "ops never writes: the same output twice, and nothing created under an empty HOME" {
  export HOME="$BATS_TEST_TMPDIR/home" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/home/.cache"
  mkdir -p "$HOME"
  a=$(ops "$OPS_GENERATE" next 2>/dev/null)
  b=$(ops "$OPS_GENERATE" next 2>/dev/null)
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

# Mutants of the frozen queue: each must be refused, not read as « rien à faire ».
@test "mutant: a missing queue file is refused" {
  run --separate-stderr ops_on "$BATS_TEST_TMPDIR/absent.json" next
  [ "$status" -eq 1 ]
  [[ $stderr == *"illisible"* ]]
}

@test "mutant: a queue without a head list is refused, not read as empty" {
  echo '{"blocked": [], "waiting": []}' >"$BATS_TEST_TMPDIR/q.json"
  run --separate-stderr ops_on "$BATS_TEST_TMPDIR/q.json" next
  [ "$status" -eq 1 ]
  [[ $stderr == *"mal formée"* ]]
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
