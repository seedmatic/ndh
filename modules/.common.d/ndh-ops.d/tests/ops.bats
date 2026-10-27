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

# ndh-ops grow (the operator's one door, 2026-10-26): rke2lab's grow by revision, from the stack home, with the
# cluster's age identity read HERE from pass, handed in RKE2LAB_CLUSTER_AGE, in the operator's own invocation, never printed, never armed.
grow_setup() {
  mkdir -p "$T/home-stack" "$T/pass"
  printf 'name: rke2lab\n' >"$T/home-stack/Pulumi.yaml"
  : "pass: prints a fake identity for its one entry; nix: records argv, cwd, and the identity's length in its env"
  cat >"$T/bin/pass" <<STUB
#!$BASH
printf '%s\n' "pass \$*" >>"$T/calls"
[ "\$1 \$2" = "show seedmatic/cluster-age/1" ] || exit 1
echo AGE-SECRET-KEY-1FAKEFAKEFAKE
STUB
  cat >"$T/bin/nix" <<STUB
#!$BASH
printf '%s\n' "nix \$* (cwd \$PWD)" >>"$T/calls"
printf 'env %s\n' "\${#RKE2LAB_CLUSTER_AGE}" >>"$T/calls"
case "\$*" in *AGE-SECRET-KEY*) echo "argv carries the identity" >>"$T/calls" ;; esac
exit \${STUB_EXIT:-0}
STUB
  chmod +x "$T/bin/pass" "$T/bin/nix"
  sed -i "1a grow_home=$T/home-stack grow_flake=github:seedmatic/rke2lab/develop cluster_age_version=1 PATH=$T/bin:\$PATH" "$T/ndh-ops"
}

@test "grow: rke2lab's grow by revision, from the stack home, the identity in its environment, never printed" {
  grow_setup
  run ops grow dev up
  [ "$status" -eq 0 ]
  grep -qx "pass show seedmatic/cluster-age/1" "$T/calls"
  grep -qx "nix --refresh run github:seedmatic/rke2lab/develop""#grow -- dev up (cwd $T/home-stack)" "$T/calls"
  : "the environment carried the identity (its length only), never argv, and nothing printed it"
  grep -qx "env 28" "$T/calls"
  run grep -c "argv carries the identity" "$T/calls"
  [ "$output" = 0 ]
  [[ $output != *"AGE-SECRET-KEY"* ]]
  run grep -c 'AGE-SECRET-KEY' "$T/state/ndh-ops/log"
  [ "$output" = 0 ]
}
@test "grow: needs no arming (the operator's own invocation), and is logged" {
  grow_setup
  run ops grow dev up
  [ "$status" -eq 0 ]
  grep -q "grow: dev up" "$T/state/ndh-ops/log"
}
@test "grow: only preview or up, a stack name only, nothing passed through" {
  grow_setup
  run ops grow dev destroy
  [ "$status" -eq 2 ]
  run ops grow '../x' up
  [ "$status" -eq 2 ]
  run ops grow dev up --target x
  [ "$status" -eq 2 ]
  : "refused before pass and nix: nothing was called at all"
  [ ! -e "$T/calls" ]
}
@test "grow: an identity pass cannot show refuses, and nix never runs" {
  grow_setup
  sed -i 's#seedmatic/cluster-age/1"#seedmatic/cluster-age/9"#' "$T/bin/pass"
  run ops grow dev up
  [ "$status" -ne 0 ]
  run grep -c '^nix ' "$T/calls"
  [ "$output" = 0 ]
}
@test "grow: its exit status is the grow's" {
  grow_setup
  STUB_EXIT=7 run ops grow dev up
  [ "$status" -eq 7 ]
}
