#!/usr/bin/env bats
# ndh::logger:command:run, the REAL one: a wrapped `set -e` script stops at its first failure and the
# wrapper says it failed; one without `set -e` runs on, as it asked; an exit code is the wrapper's;
# stdout carries the command's output and nothing else. Its log sink is a file here (LOGGER_CMD), not
# the system log a sandbox cannot reach.

# `! cmd` asserts nothing in bats: bash exempts a negated command from errexit, so it never fails a test
# unless it is the last line. refute does — and only on a NO: the command must answer 1 (grep's "no
# match"). 0 is a refutation that held; any other code (grep's 2 on a file that is not there) is no
# answer at all, and a property must not pass on one.
refute() {
  local rc=0
  "$@" || rc=$?
  case $rc in
    1) return 0 ;;
    0) echo "refuted, but it held: $*" >&2; return 1 ;;
    *) echo "refute got no answer (rc=$rc): $*" >&2; return 1 ;;
  esac
}

setup() {
  script="$BATS_TEST_TMPDIR/wrapped.sh"
  sink="$BATS_TEST_TMPDIR/sink.log"
  # A sink that only appends: `tee` would also copy the log onto the script's stdout.
  printf '#!%s\ncat >> "$1"\n' "$(command -v bash)" > "$BATS_TEST_TMPDIR/sink"
  chmod +x "$BATS_TEST_TMPDIR/sink"
  export LOGGER_CMD="$BATS_TEST_TMPDIR/sink $sink"
}

# The sink is written by a process substitution, which may end after the script: wait for the
# wrapper's last word, then look.
sink_has() { # $1 text
  local i
  for i in $(seq 30); do
    grep -qE 'completed successfully|failed \(rc=' "$sink" 2>/dev/null && break
    sleep 0.1
  done
  grep -qF -- "$1" "$sink"
}

wrapped() { # $1 header ('set -e' or ''), then the lines of main's body
  local header=$1; shift
  {
    printf '#!%s\n%s\nsource %q\n' "$BASH" "$header" "$NDH_LOGGER_SH"
    printf 'main() {\n'
    printf '  %s\n' "$@"
    printf '}\n'
    printf 'ndh::logger:command:run test-tag main\n'
  } > "$script"
}

@test "a set -e script stops at its first failure, and the wrapper says it failed" {
  wrapped 'set -euo pipefail' 'false' 'echo REACHED-AFTER-FAILURE'
  run bash "$script"
  [ "$status" -ne 0 ]
  [[ "$output" != *"REACHED-AFTER-FAILURE"* ]]
  sink_has "[test-tag] ndh::logger:command:run failed (rc=1)"
  refute grep -q "completed successfully" "$sink"
}

@test "a set -e script whose last command succeeds still fails on an earlier failure" {
  wrapped 'set -e' 'grep -q never-there /dev/null' 'true'
  run bash "$script"
  [ "$status" -ne 0 ]
  sink_has "failed (rc=1)"
}

@test "a script without set -e runs on past a failure, as it asked" {
  wrapped '' 'false' 'echo REACHED-AFTER-FAILURE'
  run bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED-AFTER-FAILURE"* ]]
  sink_has "completed successfully"
}

@test "the command's exit code is the wrapper's" {
  wrapped 'set -e' 'exit 3'
  run bash "$script"
  [ "$status" -eq 3 ]
  sink_has "failed (rc=3)"
}

@test "stdout carries the command's output and nothing of the logger" {
  wrapped 'set -e' 'echo payload-line'
  out=$(bash "$script" 2>/dev/null)
  [ "$out" = payload-line ]
}

# The operator's rule (2026-10-21): the system log tells the story, xtrace included. Traced unless the run opts out
# with NDH_LOGGER_XTRACE=0, the whole-script guard's form; any other value, or none, is traced.
@test "the command is traced into the sink by default, and untraced only with NDH_LOGGER_XTRACE=0" {
  wrapped 'set -e' 'echo marker-$((40 + 2))'
  local v
  for v in unset 1 yes; do
    : >"$sink"
    if [ "$v" = unset ]; then env -u NDH_LOGGER_XTRACE bash "$script" >/dev/null; else NDH_LOGGER_XTRACE=$v bash "$script" >/dev/null; fi
    sink_has 'completed successfully'
    grep -qF '+ echo marker-42' "$sink" || { echo "NDH_LOGGER_XTRACE=$v: not traced" >&2; return 1; }
  done
  : >"$sink"
  NDH_LOGGER_XTRACE=0 bash "$script" >/dev/null
  sink_has 'completed successfully'
  refute grep -qF '+ echo' "$sink"
}
