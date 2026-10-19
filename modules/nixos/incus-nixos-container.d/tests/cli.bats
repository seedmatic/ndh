#!/usr/bin/env bats
#
# ndh-incus-container with incus, zfs, systemctl and nix stubbed: run as `ssh host sudo …` runs it, stdin an OPEN
# pipe, no incus call may wait on stdin (live, 2026-10-18: `incus project create` and `incus init` hung
# there for a YAML). The incus stub waits for stdin a moment and fails if the wait times out; its `start`
# fails if a store device's mount point is missing, as an unprivileged LXC does (EPERM, live, same day).

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
  "query /1.0/instances/attic/state?project=ndh") echo '{"status": "Stopped"}' ;;
  "project show") exit 1 ;;
  "info --project") [ -e "$t/exists" ] ;;
  "start --project")
    for m in nix/.lower/nix/store nix/.lower/nix/var/nix nix/.upper; do
      [ -d "$t/attic/root/\$m" ] || { echo "incus start: mkdir \$m: EPERM" >&2; exit 98; }
    done ;;
esac
EOF
  cat >"$t/bin/zfs" <<EOF
#!$BASH
printf 'zfs %s\n' "\$*" >>"$t/calls"
[ "\$1" != list ]
EOF
  cat >"$t/bin/findmnt" <<EOF
#!$BASH
case "\$2" in FSTYPE) echo zfs ;; SOURCE) echo tank/x ;; esac
EOF
  # deliver copies the host DB's snapshot from a fixed path; the copy stands for it.
  cat >"$t/bin/cp" <<EOF
#!$BASH
mkdir -p "\${@: -1}"
EOF
  # The sandbox owns nothing as root: stat says 0 except for a path listed in foreign.
  cat >"$t/bin/stat" <<EOF
#!$BASH
if grep -qxF "\${@: -1}" "$t/foreign" 2>/dev/null; then echo 1000; else echo 0; fi
EOF
  printf '#!%s\necho 20261018T000000Z\n' "$BASH" >"$t/bin/date"
  printf '#!%s\nexit 1\n' "$BASH" >"$t/bin/mountpoint"
  for c in systemctl nix nix-env; do printf '#!%s\nexit 0\n' "$BASH" >"$t/bin/$c"; done
  chmod +x "$t/bin/"*
  touch "$t/x-attic"
  printf '{"upperRoot":"%s/rw","lowerdirs":["/nix/.erofs/0"]}' "$t" >"$t/layers.json"
  cli=$t/ndh-incus-container
  {
    printf 'set -euo pipefail\nexport PATH=%q:$PATH\n' "$t/bin"
    printf 'INSTANCES=%q PROJECT=ndh POOL=default PRESTART_HOOK=/run/current-system/sw/bin/ndh-incus-container-prestart\n' \
      '{"attic":{"name":"attic","target":null,"privileged":false,"dir":"'"$t"'/attic","dataset":"tank/nerd/ndh-containers/attic","toplevel":"'"$t"'/x-attic","hostStore":"local","devices":{}}}'
    printf 'GUEST_LOWER=/nix/.lower GUEST_UPPER=/nix/.upper LAYER_CONTRACT=%q STACK_DESCRIPTION=%q STORE_DEGRADED=%q GCROOTS=%q\n' \
      "$t/layers.json" "$t/stack.json" "$t/degraded" "$t/gcroots"
    cat "$BATS_TEST_DIRNAME/../cli.sh"
  } >"$cli"
  # A pipe held open by a writer that never writes: what stdin is under `ssh host sudo …`.
  mkfifo "$t/stdin"
  sleep 60 >"$t/stdin" &
  holder=$!
}

teardown() { kill "$holder" 2>/dev/null || true; }

@test "create, stdin an open pipe as over ssh: no incus call waits on it" {
  run --separate-stderr bash "$cli" create attic <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $stderr != *"waited on stdin"* ]]
  grep -q '^incus project create ndh$' "$t/calls"
  grep -q '^incus init --empty --project ndh --storage default attic ' "$t/calls"
}

@test "deliver makes the store devices' mount points before the start, and waits on no stdin" {
  touch "$t/exists"
  mkdir -p "$t/rw/.zfs/snapshot/ndh-incus-attic-20261018T000000Z/upper"
  run --separate-stderr bash "$cli" deliver attic <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $stderr != *"waited on stdin"* && $stderr != *EPERM* ]]
  grep -q '^incus start --project ndh attic$' "$t/calls"
}

@test "deliver refuses a symlink on a mount point's path: nothing snapshotted, nothing created" {
  touch "$t/exists"
  mkdir -p "$t/attic/root/nix" "$t/elsewhere"
  ln -s "$t/elsewhere" "$t/attic/root/nix/.lower"
  run --separate-stderr bash "$cli" deliver attic <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"root/nix/.lower is not root's own directory"* ]]
  [ -z "$(ls -A "$t/elsewhere")" ]
  run grep -E '^(zfs snapshot|incus start)' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "deliver refuses a component another uid owns: nothing snapshotted, nothing created" {
  touch "$t/exists"
  mkdir -p "$t/attic/root/nix"
  echo "$t/attic/root/nix" >"$t/foreign"
  run --separate-stderr bash "$cli" deliver attic <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"root/nix is not root's own directory"* ]]
  [ ! -e "$t/attic/root/nix/.lower" ]
  run grep -E '^(zfs snapshot|incus start)' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "usage names the verbs" {
  run --separate-stderr bash "$cli"
  [ "$status" -eq 2 ]
  [[ $stderr == *"ndh-incus-container create"* && $stderr == *"ndh-incus-container deliver"* ]]
}
