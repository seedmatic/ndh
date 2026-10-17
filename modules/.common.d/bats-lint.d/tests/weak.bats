#!/usr/bin/env bats
# A fixture for bats-lint: every test here carries one line that checks nothing, so the lint must refuse each.

@test "a list mid-test" {
  run false
  [ "$status" -eq 3 ] && [[ "$output" == *x* ]]
  true
}

@test "a negation mid-test" {
  ! grep -q x /dev/null
  true
}

@test "a run then a list on one line" {
  run false;  [ "$status" -eq 3 ] && [[ "$output" == *x* ]]
  true
}
