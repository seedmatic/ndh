#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.omo" "$HOME/.agents/skills/caveman" "$HOME/.agents/skills/foo"
  printf '{"disabled_skills":[],"categories":{"quick":{"model":"old"}}}' > "$HOME/.omo/omo.jsonc"
}

@test "help exits 0" {
  run omo-patch --help
  [ "$status" -eq 0 ]
}

@test "unknown command exits 2" {
  run omo-patch frobnicate
  [ "$status" -eq 2 ]
}

@test "list runs" {
  run omo-patch list
  [ "$status" -eq 0 ]
}

@test "add enables skill" {
  run omo-patch add caveman
  [ "$status" -eq 0 ]
  run yq -p json -o json -r '.disabled_skills | contains(["caveman"])' "$HOME/.omo/omo.jsonc" 2>/dev/null
  [ "$output" = "false" ]
}

@test "remove disables skill" {
  run omo-patch remove caveman
  [ "$status" -eq 0 ]
  run yq -p json -o json -r '.disabled_skills | contains(["caveman"])' "$HOME/.omo/omo.jsonc" 2>/dev/null
  [ "$output" = "true" ]
}

@test "profile applies" {
  printf '{"disabled_skills":["caveman"],"categories":{"quick":{"model":"old"}}}' > "$HOME/.omo/omo.jsonc"
  run omo-patch --profile opencode-go
  [ "$status" -eq 0 ]
  run yq -p json -o json -r '.categories.quick.model' "$HOME/.omo/omo.jsonc" 2>/dev/null
  [ "$output" = "litellm-bioskop/agent" ]
}

@test "profile idempotent" {
  run omo-patch --profile opencode-go
  [ "$status" -eq 0 ]
}

@test "dry-run no changes" {
  cp "$HOME/.omo/omo.jsonc" "$BATS_TEST_TMPDIR/before.json"
  run omo-patch --dry-run --profile opencode-go
  [ "$status" -eq 0 ]
  run diff "$BATS_TEST_TMPDIR/before.json" "$HOME/.omo/omo.jsonc"
  [ "$status" -eq 0 ]
}
