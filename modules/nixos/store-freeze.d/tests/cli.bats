#!/usr/bin/env bats
#
# ndh-store's gestures with every system tool stubbed (zfs, nix-store, nix-env, systemctl, mount): each stub logs
# its call, so a test reads what a gesture changed. The rule under test: every refusal comes before the first
# change, and an unsealed layer never outlives the gesture.

bats_require_minimum_version 1.5.0

# The wrapper's tools, exactly (runtime-inputs.nix): the program sees nothing else but the stubs.
: "${TOOLS_PATH:?the suite needs TOOLS_PATH: the tools of the wrapper}"

setup() {
  t=$BATS_TEST_TMPDIR
  log=$t/calls
  : >"$log"
  mkdir -p "$t/bin" "$t/upper" "$t/erofs" "$t/run" "$t/stack" "$t/builds" "$t/profiles" "$t/sys/bin"
  # The current system, booted, and its profile with one old generation.
  ln -s "$t/sys" "$t/current-system"
  ln -s "$t/sys" "$t/booted-system"
  ln -s "$t/sys" "$t/profiles/system-2-link"
  ln -s "$t/old-sys" "$t/profiles/system-1-link"
  ln -s system-2-link "$t/profiles/system"
  printf '#!%s\necho "switch-to-configuration $*" >>%q\n' "$BASH" "$log" >"$t/sys/bin/switch-to-configuration"
  chmod +x "$t/sys/bin/switch-to-configuration"
  echo '{"manifest": "current", "frozen": []}' >"$t/run/store-stack.json"
  : >"$t/rw-upper.base"
  stub zfs 'case "$1" in list) exit 0 ;; get) echo 4242 ;; snapshot) [ -z "${FAIL_SNAPSHOT:-}" ] || exit 1 ;; esac'
  stub nix-store '
    case "$*" in
      "--gc --print-live") cat "$T/live" ;;
      "--gc") ;;
      "--verify") ;;
      "-q --hash "*) echo "sha256:$(basename "$3")" ;;
      "-q --deriver "*) shift 2; for p in "$@"; do echo unknown-deriver; done ;;
      "--check-validity --print-invalid"*) ;;
      *) ;;
    esac'
  stub nix-env ''
  stub systemctl ''
  stub mount ''
  # A stubbed mount puts the layer's files in the mount point itself; unmounting hides them again.
  stub umount 'find "$1" -mindepth 1 -delete'
  stub pgrep 'exit 1'
  stub getent 'echo "nixbld:x:30000:"'
  stub sync ''
  # Two live paths in the upper: a clean one, and one with a secret shape unless a test removes it.
  echo hello >"$t/upper/aaaa-clean"
  # Assembled at run time: this file must hold no secret shape, or ndh's own source would trip the sweep.
  printf '%s-%s-%s-1%s\n' AGE SECRET KEY "QWERTYUIOPASDFGHJKLZXCVBNM" >"$t/upper/bbbb-secret"
  printf '/nix/store/aaaa-clean\n/nix/store/bbbb-secret\n' >"$t/live"
  cli=$t/ndh-store
  {
    printf 'set -euo pipefail\nexport PATH=%q:%q T=%q INCUS_ENABLED=${INCUS_ENABLED:-false}\n' "$t/bin" "$TOOLS_PATH" "$t"
    printf 'export RW_DATASET=tank/rw DB_DATASET=tank/db LAYERS_DATASET=tank/layers RW_MOUNT=%q\n' "$t/rw"
    printf 'export STACK_DIR=%q FROZEN_ROOT=%q EROFS_LOWERS=%q RUN_DIR=%q MANIFEST_VERSION=2\n' \
      "$t/stack" "$t/frozen" "$t/erofs" "$t/run"
    printf 'export SWEEP_SHAPES=%q CONTAINER_PROJECT=ndh CONTAINER_STATE_ROOT=%q\n' \
      "$BATS_TEST_DIRNAME/../sweep-shapes" "$t/containers"
    printf 'export SYSTEM_PROFILE=%q CURRENT_SYSTEM=%q BOOTED_SYSTEM=%q NIX_BUILDS_DIR=%q\n' \
      "$t/profiles/system" "$t/current-system" "$t/booted-system" "$t/builds"
    cat "$BATS_TEST_DIRNAME/../cli.sh"
  } >"$cli"
  # The upper lives at $RW_MOUNT/upper; upper.base beside it.
  mkdir -p "$t/rw"
  mv "$t/upper" "$t/rw/upper"
  mv "$t/rw-upper.base" "$t/rw/upper.base"
}

# stub {name} {body}: a command on PATH that logs its call, then runs the body.
stub() {
  printf '#!%s\necho "%s $*" >>%q\n%s\n' "$BASH" "$1" "$log" "$2" >"$t/bin/$1"
  chmod +x "$t/bin/$1"
}

run_cli() { run --separate-stderr bash "$cli" "$@"; }

# changed: did a call that changes the machine happen?
changed() {
  grep -E '^(nix-env .*--delete-generations|switch-to-configuration|nix-store --gc$|nix-store --delete|zfs (create|snapshot|destroy|set)|systemctl reboot)' "$log"
}

@test "compact refused by the sweep changes nothing: no generation, no bootloader, no GC, no layer, nix back" {
  run_cli compact "$t/sys"
  [ "$status" -eq 1 ]
  [[ $stderr == *"1 paths hold a secret shape"* && $stderr == *"bbbb-secret"* ]]
  [[ $stderr == *"nothing compacted"* ]]
  run changed
  [ "$status" -eq 1 ]
  grep -qx 'systemctl start nix-daemon.socket' "$log"
  [ -z "$(ls -A "$t/run/build" 2>/dev/null)" ]
}

@test "compact --accept lets the accepted path through, bound to its hash, and folds" {
  run_cli compact --accept /nix/store/bbbb-secret "$t/sys"
  [ "$status" -eq 0 ]
  [[ $stderr == *"were ACCEPTED, bound to their narHash"* ]]
  grep -q 'nix-env -p .* --delete-generations old' "$log"
  grep -qx 'switch-to-configuration boot' "$log"
  grep -q '^zfs snapshot tank/layers/ndh-store-' "$log"
  grep -qx 'systemctl reboot' "$log"
  grep -qx 'bbbb-secret sha256:bbbb-secret' "$t/stack/accepted"
  [ -s "$t/stack/next.json" ]
  # Sealed: its mount point is gone with it.
  [ -z "$(ls -A "$t/run/build" 2>/dev/null)" ]
}

@test "compact with a clean store folds, and leaves no build directory" {
  rm "$t/rw/upper/bbbb-secret"
  echo /nix/store/aaaa-clean >"$t/live"
  run_cli compact "$t/sys"
  [ "$status" -eq 0 ]
  grep -q '^zfs create -o mountpoint=legacy tank/layers/ndh-store-' "$log"
  [ -z "$(ls -A "$t/run/build" 2>/dev/null)" ]
}

@test "a failure after the layer is built drops it and its mount point, and nix comes back" {
  rm "$t/rw/upper/bbbb-secret"
  echo /nix/store/aaaa-clean >"$t/live"
  FAIL_SNAPSHOT=1 run_cli compact "$t/sys"
  [ "$status" -ne 0 ]
  grep -q '^zfs destroy -r tank/layers/ndh-store-' "$log"
  grep -qx 'systemctl start nix-daemon.socket' "$log"
  [ -z "$(ls -A "$t/run/build" 2>/dev/null)" ]
  [ ! -e "$t/stack/next.json" ]
}

@test "a compact --accept refused before the sweep records no acceptance" {
  touch "$t/run/store-degraded"
  run_cli compact --accept /nix/store/bbbb-secret "$t/sys"
  [ "$status" -eq 1 ]
  [[ $stderr == *"degraded"* ]]
  [ ! -e "$t/stack/accepted" ]
  rm "$t/run/store-degraded"
  rm "$t/booted-system"
  ln -s "$t/old-sys" "$t/booted-system"
  run_cli compact --accept /nix/store/bbbb-secret "$t/sys"
  [ "$status" -eq 1 ]
  [ ! -e "$t/stack/accepted" ]
}

@test "usage names the verbs" {
  run_cli
  [ "$status" -eq 2 ]
  [[ $stderr == *"ndh-store compact"* ]]
}

@test "a live path spread over two layers above the EROFS ones is refused before anything" {
  # A non-opaque directory in the upper, also present in a frozen layer below it.
  mkdir -p "$t/rw/upper/dddd-spread" "$t/frozen-a/dddd-spread"
  echo '{"manifest": "current", "frozen": ["'"$t/frozen-a"'"]}' >"$t/run/store-stack.json"
  rm "$t/rw/upper/bbbb-secret"
  printf '/nix/store/aaaa-clean\n/nix/store/dddd-spread\n' >"$t/live"
  run_cli compact "$t/sys"
  [ "$status" -eq 1 ]
  [[ $stderr == *"dddd-spread is spread over"* ]]
  run changed
  [ "$status" -eq 1 ]
}

@test "with Incus enabled, a missing incus refuses before anything" {
  rm "$t/rw/upper/bbbb-secret"
  echo /nix/store/aaaa-clean >"$t/live"
  INCUS_ENABLED=true run_cli compact "$t/sys"
  [ "$status" -eq 1 ]
  [[ $stderr == *"Incus is enabled but incus is not"* ]]
  run changed
  [ "$status" -eq 1 ]
}

@test "with Incus enabled, a failed container listing refuses before anything; a good one stops them before the reboot" {
  rm "$t/rw/upper/bbbb-secret"
  echo /nix/store/aaaa-clean >"$t/live"
  stub incus 'case "$1" in list) [ -z "${FAIL_LIST:-}" ] || exit 1; echo attic ;; esac'
  INCUS_ENABLED=true FAIL_LIST=1 run_cli compact "$t/sys"
  [ "$status" -eq 1 ]
  [[ $stderr == *"cannot list the Incus containers"* ]]
  run changed
  [ "$status" -eq 1 ]
  : >"$log"
  INCUS_ENABLED=true run_cli compact "$t/sys"
  [ "$status" -eq 0 ]
  grep -qx 'incus stop --project ndh attic' "$log"
}

@test "compact before the current system has booted is refused before anything" {
  rm "$t/booted-system"
  ln -s "$t/old-sys" "$t/booted-system"
  run_cli compact "$t/sys"
  [ "$status" -eq 1 ]
  [[ $stderr == *"has not booted yet"* ]]
  [ ! -s "$log" ] || ! grep -q '^systemctl stop' "$log"
}

@test "freeze refused by the sweep changes nothing: no GC, no snapshot" {
  run_cli freeze "$t/sys"
  [ "$status" -eq 1 ]
  [[ $stderr == *"nothing frozen"* ]]
  run changed
  [ "$status" -eq 1 ]
}

@test "purge refused because the layers left would hold a secret changes nothing: no path deleted" {
  printf 'cccc-other\n' >"$t/rw/upper/cccc-other"
  printf '/nix/store/aaaa-clean\n/nix/store/bbbb-secret\n/nix/store/cccc-other\n' >"$t/live"
  stub nix-store '
    case "$*" in
      "--gc --print-live") cat "$T/live" ;;
      "--query --referrers-closure "*) echo /nix/store/cccc-other ;;
      "--gc --print-roots") ;;
      "-q --deriver "*) shift 2; for p in "$@"; do echo unknown-deriver; done ;;
      *) ;;
    esac'
  run_cli purge --yes /nix/store/cccc-other
  [ "$status" -eq 1 ]
  [[ $stderr == *"would still hold a secret shape"* ]]
  run changed
  [ "$status" -eq 1 ]
}
