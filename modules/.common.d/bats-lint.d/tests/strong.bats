#!/usr/bin/env bats
# A fixture for bats-lint: the forms that do check, which the lint must accept.

@test "one check per line" {
  run false
  [ "$status" -eq 1 ]
  [[ "$output" == "" ]]
}

@test "a negation that fails the test" {
  ! grep -q x /dev/null || false
  true
}

@test "a list or a negation as the last command" {
  run false
  [ "$status" -eq 1 ] && [[ "$output" == "" ]]
}

@test "a && inside a single [[ ]]" {
  [[ a == a && b == b ]]
  true
}

@test "a guard in a loop" {
  for l in a -b; do [[ "$l" == -* ]] && continue; done
  true
}

@test "a one-line test" { [ 1 -eq 1 ] && [ 2 -eq 2 ]; }
