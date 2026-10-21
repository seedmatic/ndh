#!/usr/bin/env bats
# flox-config, the PACKAGED program ($FLOX_CONFIG), on a flox.toml shaped like the seats': the operator's hand-kept
# key with its comment, the token key to remove, a section. Every key the expression does not name stays.

bats_require_minimum_version 1.5.0

ARGS=(--set auth_notifications false --delete floxhub_token_storage)

setup() {
  f="$BATS_TEST_TMPDIR/flox/flox.toml"
  mkdir -p "${f%/*}"
  cat >"$f" <<'EOF'
# kept by hand
auto_activate_environments = ["~/dev/a", "~/dev/b"] # the operator's
floxhub_token_storage = "keyring"

[features]
search = true
EOF
  chmod 0600 "$f"
}

value() { yq -p toml -o json -I0 "$1" "$f"; }

@test "the declared key is set and the removed one is gone" {
  run "$FLOX_CONFIG" "$f" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [ "$(value .auth_notifications)" = false ]
  [ "$(value 'has("floxhub_token_storage")')" = false ]
}

@test "a new key lands at the top level, not in the last table" {
  run "$FLOX_CONFIG" "$f" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [ "$(value '.features | has("auth_notifications")')" = false ]
}

@test "an existing key is changed in place" {
  "$FLOX_CONFIG" "$f" "${ARGS[@]}"
  run "$FLOX_CONFIG" "$f" --set auth_notifications true
  [ "$status" -eq 0 ]
  [ "$(value .auth_notifications)" = true ]
  [ "$(grep -c '^auth_notifications' "$f")" = 1 ]
}

@test "every other line stays byte for byte, the hand-kept key and its comment included" {
  run "$FLOX_CONFIG" "$f" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -qxF 'auto_activate_environments = ["~/dev/a", "~/dev/b"] # the operator'"'"'s' "$f"
  grep -qxF '# kept by hand' "$f"
}

@test "every key it does not name stays, the hand-kept one and its comment included" {
  run "$FLOX_CONFIG" "$f" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [ "$(value .auto_activate_environments)" = '["~/dev/a","~/dev/b"]' ]
  [ "$(value .features.search)" = true ]
  grep -qF "# the operator's" "$f"
}

@test "the file keeps its mode" {
  run "$FLOX_CONFIG" "$f" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$f")" = 600 ]
}

@test "a second run changes nothing and says nothing" {
  "$FLOX_CONFIG" "$f" "${ARGS[@]}"
  before=$(cat "$f")
  run "$FLOX_CONFIG" "$f" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$f")" = "$before" ]
}

@test "a missing file is created with the declared keys only" {
  rm "$f"
  run "$FLOX_CONFIG" "$f" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [ "$(value .auth_notifications)" = false ]
  [ "$(value 'keys | length')" = 1 ]
}

@test "a value that is not TOML leaves the file as it was" {
  before=$(cat "$f")
  run "$FLOX_CONFIG" "$f" --set auth_notifications 'not toml'
  [ "$status" -ne 0 ]
  [ "$(cat "$f")" = "$before" ]
}

@test "a key that is not bare is refused" {
  before=$(cat "$f")
  run "$FLOX_CONFIG" "$f" --set 'a.b' true
  [ "$status" -eq 2 ]
  [ "$(cat "$f")" = "$before" ]
}
