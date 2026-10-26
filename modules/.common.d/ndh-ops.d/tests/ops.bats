#!/usr/bin/env bats
# ndh-ops against a throwaway delegation directory, no sudo, and stub tools that record their argv.

setup() {
  D="$BATS_TEST_DIRNAME/.."
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" XDG_STATE_HOME="$T/state"
  mkdir -p "$HOME" "$T/bin"
  for t in ssh-keys-renew ndh-keyring; do
    printf '#!%s\nprintf "%%s\\n" "%s $*" >>"%s/calls"\nexit ${STUB_EXIT:-0}\n' "$BASH" "$t" "$T" >"$T/bin/$t"
    chmod +x "$T/bin/$t"
  done
  { printf 'dir=%q\nsudo=\nmax_hours=72\n' "$T/db"
    printf 'declare -A tools=([ssh-keys-renew]=%q [ndh-keyring]=%q)\n' "$T/bin/ssh-keys-renew" "$T/bin/ndh-keyring"
    printf 'items=(%s)\n' "${ARMING_ITEMS:?ndh-ops.d/paths.nix armingItems, from the flake check}"
    cat "$D/ndh-ops.sh"; } >"$T/ndh-ops"
}

ops() { bash "$T/ndh-ops" "$@"; }

@test "not armed: a tool is refused, nothing runs" {
  run ops ssh-keys-renew --apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"no unexpired delegation names ssh-keys-renew"* ]]
  [ ! -e "$T/calls" ]
}
@test "armed for a tool: it runs with its arguments, and the run is logged" {
  ops arm --hours 2 --tools ssh-keys-renew
  run ops ssh-keys-renew --older-than 30d --apply
  [ "$status" -eq 0 ]
  grep -qx "ssh-keys-renew --older-than 30d --apply" "$T/calls"
  grep -q "run: ssh-keys-renew --older-than 30d --apply" "$T/state/ndh-ops/log"
  grep -q "done: ssh-keys-renew exit 0" "$T/state/ndh-ops/log"
}
@test "armed for one tool: another stays refused" {
  ops arm --hours 2 --tools ssh-keys-renew
  run ops ndh-keyring status
  [ "$status" -eq 3 ] && [ ! -e "$T/calls" ]
}
@test "a tool's exit status is returned and logged" {
  ops arm --hours 1 --tools ndh-keyring
  STUB_EXIT=5 run ops ndh-keyring status
  [ "$status" -eq 5 ]
  grep -q "done: ndh-keyring exit 5" "$T/state/ndh-ops/log"
}
@test "an expired delegation refuses" {
  ops arm --hours 1 --tools ssh-keys-renew
  sed -i.bak "s/^expires=.*/expires=$(($(date +%s) - 1))/" "$T/db/delegation"
  run ops ssh-keys-renew
  [ "$status" -eq 3 ] && [ ! -e "$T/calls" ]
}
@test "a malformed expiry counts as not armed" {
  ops arm --hours 1 --tools ssh-keys-renew
  sed -i.bak 's/^expires=.*/expires=soon/' "$T/db/delegation"
  run ops ssh-keys-renew
  [ "$status" -eq 3 ]
  run ops status
  [ "$output" = "not armed" ]
}
@test "a prefix of an armed tool's name is not that tool" {
  ops arm --hours 1 --tools ssh-keys-renew
  sed -i.bak 's/^tools=.*/tools=ssh-keys-renewal/' "$T/db/delegation"
  run ops ssh-keys-renew
  [ "$status" -eq 3 ]
}
@test "an unknown tool is refused" {
  run ops rm -rf /
  [ "$status" -eq 3 ]
  [[ "$output" == *"rm is not an operator tool"* ]]
}
@test "arm: hours out of range, a missing or unknown tool are refused" {
  run ops arm --hours 0 --tools ssh-keys-renew;  [ "$status" -eq 3 ]
  run ops arm --hours 73 --tools ssh-keys-renew; [ "$status" -eq 3 ]
  run ops arm --hours 2;                         [ "$status" -eq 3 ]
  run ops arm --hours 2 --tools gpg;             [ "$status" -eq 3 ]
  [[ "$output" == *"gpg is not one of"* ]]
  [ ! -e "$T/db/delegation" ]
}
@test "arm: the root's ceremony is never delegated" {
  run ops arm --hours 2 --tools ndh-ceremony-vm
  [ "$status" -eq 3 ]
  [[ "$output" == *"ndh-ceremony-vm is not one of"* ]]
  [ ! -e "$T/db/delegation" ]
}
@test "the root's ceremony is refused, its smoke form too" {
  run ops ndh-ceremony-vm --smoke
  [ "$status" -eq 3 ]
  [[ "$output" == *"ndh-ceremony-vm is not an operator tool"* ]]
}
@test "status and disarm" {
  run ops status; [ "$output" = "not armed" ]
  ops arm --hours 3 --tools ssh-keys-renew,ndh-keyring
  run ops status; [[ "$output" == "armed: ssh-keys-renew,ndh-keyring, until "* ]]
  ops disarm
  run ops status; [ "$output" = "not armed" ]
  run ops ndh-keyring; [ "$status" -eq 3 ]
}
@test "the delegation records who armed it and when" {
  ops arm --hours 1 --tools ndh-keyring
  grep -q "^armed_by=$(id -un)$" "$T/db/delegation"
  grep -q '^armed_at=20' "$T/db/delegation"
}

# An arming item names a permission a tool checks itself, not a program: fleet-switch requires fleet-switch-seat beside
# fleet-switch for --with-seat (the operator's decision, 2026-10-26). arm writes it; nobody runs it.
@test "arm: an arming item is accepted beside its tool, and written into the delegation" {
  run ops arm --hours 1 --tools fleet-switch-seat,ssh-keys-renew
  [ "$status" -eq 0 ]
  grep -qx 'tools=fleet-switch-seat,ssh-keys-renew' "$T/db/delegation"
}
@test "an arming item is not a tool: running it is refused, even armed" {
  ops arm --hours 1 --tools fleet-switch-seat
  run ops fleet-switch-seat
  [ "$status" -eq 3 ]
  [[ "$output" == *"fleet-switch-seat is not an operator tool"* ]]
}
@test "arm: a name that only contains an item is refused" {
  run ops arm --hours 1 --tools fleet-switch-seatx
  [ "$status" -eq 3 ]
  [ ! -e "$T/db/delegation" ]
}
@test "mutant: without the item list, arm refuses the item (the 2026-10-26 refusal)" {
  sed -i '/^items=(/d' "$T/ndh-ops"
  run grep -c '^items=' "$T/ndh-ops"
  [ "$output" = 0 ]
  run ops arm --hours 1 --tools fleet-switch-seat
  [ "$status" -eq 3 ]
  [[ "$output" == *"arm: fleet-switch-seat is not one of"* ]]
}
