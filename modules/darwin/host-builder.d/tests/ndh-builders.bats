#!/usr/bin/env bats
# ndh-builders on throwaway lists: it switches the pointer by a rename, refuses a mode whose list nix would skip
# silently, and reports a pointer that leads nowhere.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/etc"
  echo "ssh-ng://nix-store.home aarch64-darwin - 3 10 - - -" >"$t/etc/machines.metalspace"
  cat "$t/etc/machines.metalspace" >"$t/etc/machines.fabric"
  echo "ssh-ng://nix-store.peer aarch64-darwin - 1 1 - - -" >>"$t/etc/machines.fabric"
  {
    printf '#!%s\nset -euo pipefail\n' "$BASH"
    printf 'dir=%q machines=%q modes=%q\n' "$t/var/builders" "$t/etc/machines" "fabric metalspace"
    cat "$BATS_TEST_DIRNAME/../ndh-builders.sh"
  } >"$t/ndh-builders"
  chmod +x "$t/ndh-builders"
}

@test "a mode points the active list at its file, and the status names it" {
  run --separate-stderr "$t/ndh-builders" fabric
  [ "$status" -eq 0 ]
  [ "$(readlink "$t/var/builders/active")" = "$t/etc/machines.fabric" ]
  run --separate-stderr "$t/ndh-builders"
  [ "$status" -eq 0 ]
  [ "$output" = fabric ]
  "$t/ndh-builders" metalspace
  [ "$("$t/ndh-builders")" = metalspace ]
  [ ! -e "$t/var/builders/active.new" ]
}

@test "a mode whose list is missing or empty is refused, and the active one is kept" {
  "$t/ndh-builders" metalspace
  : >"$t/etc/machines.fabric"
  run --separate-stderr "$t/ndh-builders" fabric
  [ "$status" -eq 1 ]
  [[ $stderr == *"missing or empty"* ]]
  [ "$(readlink "$t/var/builders/active")" = "$t/etc/machines.metalspace" ]
}

@test "an unknown mode or a second argument is refused, and nothing is written" {
  run --separate-stderr "$t/ndh-builders" everything
  [ "$status" -eq 1 ]
  [[ $stderr == *"usage: ndh-builders [fabric | metalspace]"* ]]
  run --separate-stderr "$t/ndh-builders" metal
  [ "$status" -eq 1 ]
  run --separate-stderr "$t/ndh-builders" metalspace fabric
  [ "$status" -eq 1 ]
  [ ! -e "$t/var/builders" ]
}

@test "no pointer, or one that leads nowhere, fails the status" {
  run --separate-stderr "$t/ndh-builders"
  [ "$status" -eq 1 ]
  [[ $stderr == *"no active builders set"* ]]
  "$t/ndh-builders" fabric
  rm "$t/etc/machines.fabric"
  run --separate-stderr "$t/ndh-builders"
  [ "$status" -eq 1 ]
  [[ $stderr == *"missing or empty"* ]]
}

@test "a directory it may not write is refused, and the pointer stays" {
  "$t/ndh-builders" metalspace
  chmod 0555 "$t/var/builders"
  run --separate-stderr "$t/ndh-builders" fabric
  chmod 0755 "$t/var/builders"
  [ "$status" -eq 1 ]
  [[ $stderr == *"root only"* ]]
  [ "$(readlink "$t/var/builders/active")" = "$t/etc/machines.metalspace" ]
}
