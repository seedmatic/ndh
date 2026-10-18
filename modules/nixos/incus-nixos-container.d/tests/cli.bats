#!/usr/bin/env bats
#
# ndh-incus-container with incus, zfs and systemctl stubbed: run as `ssh host sudo …` runs it, stdin an OPEN
# pipe, no incus call may wait on stdin (live, 2026-10-18: `incus project create` and `incus init` hung
# there for a YAML). The incus stub waits for stdin a moment and fails if the wait times out.

bats_require_minimum_version 1.5.0

setup() {
  t=$BATS_TEST_TMPDIR
  mkdir -p "$t/bin"
  cat >"$t/bin/incus" <<EOF
#!$BASH
printf 'incus %s\n' "\$*" >>"$t/calls"
# A read that times out (status > 128) means stdin was left open: the real incus would hang there.
read -r -t 2 _
if [ \$? -gt 128 ]; then echo "incus \$* waited on stdin" >&2; exit 99; fi
case "\$1 \$2" in
  "query /1.0/cluster") echo '{"enabled": false}' ;;
  "project show") exit 1 ;;
  "info --project") exit 1 ;;
esac
exit 0
EOF
  cat >"$t/bin/zfs" <<EOF
#!$BASH
printf 'zfs %s\n' "\$*" >>"$t/calls"
[ "\$1" != list ]
EOF
  chmod +x "$t/bin/"*
  cli=$t/ndh-incus-container
  {
    printf 'set -euo pipefail\nexport PATH=%q:$PATH\n' "$t/bin"
    printf 'INSTANCES=%q PROJECT=ndh POOL=default PRESTART_HOOK=/run/current-system/sw/bin/ndh-incus-container-prestart\n' \
      '{"attic":{"name":"attic","target":null,"privileged":false,"dir":"'"$t"'/attic","dataset":"tank/nerd/ndh-containers/attic","toplevel":"/nix/store/x-attic","hostStore":"local","devices":{}}}'
    cat "$BATS_TEST_DIRNAME/../cli.sh"
  } >"$cli"
}

@test "create, stdin an open pipe as over ssh: no incus call waits on it" {
  # A pipe held open by a writer that never writes: what stdin is under `ssh host sudo …`.
  mkfifo "$t/stdin"
  sleep 60 >"$t/stdin" &
  holder=$!
  run --separate-stderr bash "$cli" create attic <"$t/stdin"
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ $stderr != *"waited on stdin"* ]]
  grep -q '^incus project create ndh$' "$t/calls"
  grep -q '^incus init --empty --project ndh --storage default attic ' "$t/calls"
}

@test "usage names the verbs" {
  run --separate-stderr bash "$cli"
  [ "$status" -eq 2 ]
  [[ $stderr == *"ndh-incus-container create"* && $stderr == *"ndh-incus-container deliver"* ]]
}
