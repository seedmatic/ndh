#!/usr/bin/env bats
#
# ndh-attic-tokens-deposit on its real path, the outside world stubbed: ssh (records the target and the remote
# command, keeps the frame) and the local sudo (records, keeps the seat's frame).

bats_require_minimum_version 1.5.0

setup() {
  t=$BATS_TEST_TMPDIR
  mkdir -p "$t/bin" "$t/out/bioskop" "$t/out/bioskop-nixos" "$t/out/nikopol"
  for m in bioskop bioskop-nixos nikopol; do
    printf 'age-encryption.org/v1\n-> X25519 %s\n' "$m" >"$t/out/$m/netrc.bioskop.age"
  done
  printf 'age-encryption.org/v1\n-> X25519 w\n' >"$t/out/bioskop-nixos/write.token.age"
  {
    printf '#!%s\n' "$BASH"
    printf 'host="${@: -2:1}"\n'
    printf 'printf "%%s %%s\\n" "$host" "${@: -1}" >>%q\n' "$t/ssh.log"
    printf 'cat >%q."$host"\n' "$t/frame"
    printf '[[ $host != "${STUB_FAIL:-none}" ]]\n'
  } >"$t/bin/ssh"
  {
    printf '#!%s\n' "$BASH"
    printf '[[ $1 == -n ]] || exit 96\nshift\n'
    printf 'printf "%%s\\n" "$*" >>%q\n' "$t/sudo.log"
    printf 'cat >%q\n' "$t/frame.local"
  } >"$t/sudo"
  chmod +x "$t/bin/ssh" "$t/sudo"
  {
    printf 'set -euo pipefail\n'
    printf 'seat=bioskop localSudo=%q localReceive=/store/ndh-attic-tokens-receive\n' "$t/sudo"
    printf 'declare -A targetKind=([bioskop-nixos]=nixos [nikopol-nixos]=nixos [nikopol]=darwin)\n'
    printf 'declare -A targetSsh=([bioskop-nixos]=nixos.bioskop [nikopol-nixos]=nixos.nikopol [nikopol]=darwin.nikopol)\n'
    cat "$BATS_TEST_DIRNAME/../deposit.sh"
  } >"$t/deposit"
}

deposit() { PATH="$t/bin:$PATH" run --separate-stderr bash "$t/deposit" "$@"; }
item_of() { printf 'item %s %s' "$(basename "$1")" "$(base64 <"$1" | tr -d '\n')"; }

@test "each machine's dir goes to that machine alone: the seat locally, the others by their ssh name and kind" {
  deposit "$t/out"
  [ "$status" -eq 0 ]
  [ "$(<"$t/sudo.log")" = /store/ndh-attic-tokens-receive ]
  grep -qx 'nixos.bioskop /run/wrappers/bin/sudo -n /run/current-system/sw/bin/ndh-attic-tokens-receive' "$t/ssh.log"
  grep -qx 'darwin.nikopol /usr/bin/sudo -n /run/current-system/sw/bin/ndh-attic-tokens-receive' "$t/ssh.log"
  [ "$(wc -l <"$t/ssh.log")" -eq 2 ]
  [ "$(head -n 1 "$t/frame.nixos.bioskop")" = "ndh-attic-tokens/1 bioskop-nixos" ]
  grep -qxF "$(item_of "$t/out/bioskop-nixos/write.token.age")" "$t/frame.nixos.bioskop"
  grep -qxF "$(item_of "$t/out/nikopol/netrc.bioskop.age")" "$t/frame.darwin.nikopol"
  [ "$(head -n 1 "$t/frame.local")" = "ndh-attic-tokens/1 bioskop" ]
  [ "$(tail -n 1 "$t/frame.local")" = end ]
  [[ $stderr == *"deposited on: bioskop bioskop-nixos nikopol"* ]]
}

@test "a dir for a machine outside the inventory: nothing is sent at all" {
  mkdir -p "$t/out/elsewhere"
  deposit "$t/out"
  [ "$status" -eq 1 ]
  [[ $stderr == *"elsewhere: not a machine of the inventory — nothing sent"* ]]
  [ ! -e "$t/ssh.log" ] && [ ! -e "$t/sudo.log" ]
}

@test "a machine that refuses is reported, and the others are still deposited" {
  STUB_FAIL=darwin.nikopol deposit "$t/out"
  [ "$status" -eq 1 ]
  [[ $stderr == *"deposited on: bioskop bioskop-nixos"* ]]
  [[ $stderr == *"not deposited on: nikopol"* ]]
}
