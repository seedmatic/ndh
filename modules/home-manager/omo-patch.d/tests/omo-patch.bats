#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.omo" "$HOME/.agents/skills/caveman" "$HOME/.agents/skills/foo"
  printf '{"disabled_skills":[],"categories":{"quick":{"model":"old"},"deep-low":{"model":"old"}}}' > "$HOME/.omo/omo.jsonc"
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
  printf '{"disabled_skills":["caveman"],"categories":{"quick":{"model":"old"},"deep-low":{"model":"old"}}}' > "$HOME/.omo/omo.jsonc"
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

@test "a profile leaves disabled_skills alone, whatever skills are installed" {
  printf '{"disabled_skills":["caveman","hyperplan","ulw-plan"],"categories":{"quick":{"model":"old"},"deep-low":{"model":"old"}}}' > "$HOME/.omo/omo.jsonc"
  run omo-patch --profile opencode-go
  [ "$status" -eq 0 ]
  run yq -p json -o json -I=0 '.disabled_skills' "$HOME/.omo/omo.jsonc"
  [ "$output" = '["caveman","hyperplan","ulw-plan"]' ]
}

@test "set refuses a path whose parent does not exist" {
  printf '{"providers":{"aikey":{"baseUrl":"x","apiKey":"k"}}}' > "$HOME/.omo/agent-models.json"
  mkdir -p "$BATS_TEST_TMPDIR/frag/omo.d"
  printf 'profile: p\ntargets:\n  - path: %s\n    kind: json\n    patches:\n      - op: set\n        path: .providers.nope.baseUrl\n        value: y\n' "$HOME/.omo/agent-models.json" > "$BATS_TEST_TMPDIR/frag/omo.d/p.yaml"
  FRAGMENTS_DIR="$BATS_TEST_TMPDIR/frag" run omo-patch --profile p
  [ "$status" -ne 0 ]
  run yq -p json -o json -I=0 '.providers | keys' "$HOME/.omo/agent-models.json"
  [ "$output" = '["aikey"]' ]
}

@test "nikopol-aikey repoints the provider and keeps its models" {
  mkdir -p "$HOME/.omo/agent"
  printf '{"providers":{"aikey-nikopol":{"baseUrl":"http://nixos.nikopol:4001/v1","apiKey":"aikey","models":[{"id":"m"}]}}}' > "$HOME/.omo/agent/models.json"
  run omo-patch --profile nikopol-aikey
  [ "$status" -eq 0 ]
  run yq -p json -o json -I=0 '.providers."aikey-nikopol" | [.baseUrl, .apiKey, (.models | length)]' "$HOME/.omo/agent/models.json"
  [ "$output" = '["http://127.0.0.1:4000/v1","ehlo",1]' ]
}

@test "dry-run holds for add and remove too, and leaves no backup" {
  cp "$HOME/.omo/omo.jsonc" "$BATS_TEST_TMPDIR/before.json"
  run omo-patch add caveman --dry-run
  [ "$status" -eq 0 ]
  run omo-patch --dry-run remove caveman
  [ "$status" -eq 0 ]
  run diff "$BATS_TEST_TMPDIR/before.json" "$HOME/.omo/omo.jsonc"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.agents/.skill-lock.json" ]
  [ -z "$(find "$HOME" -name '*.omo-patch.bak.*')" ]
}

