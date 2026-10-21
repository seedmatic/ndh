#!/usr/bin/env bats
# ndh::secret:begin / ndh::secret:end, the REAL ones: inside a window nothing is traced and a child sees
# NDH_LOGGER_XTRACE=0; the trace says where the window was (`: "secret window: <why>"`); end gives back
# exactly what begin found, xtrace and marker, nesting included; a failure inside a window never traces the
# value, not even from an EXIT trap.

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
  script="$BATS_TEST_TMPDIR/windowed.sh"
  trace="$BATS_TEST_TMPDIR/trace"
}

# `run` folds stderr into $output: the trace goes to its own file instead.
traced() {
  status=0
  bash -x "$script" >"$BATS_TEST_TMPDIR/out" 2>"$trace" || status=$?
  output=$(cat "$BATS_TEST_TMPDIR/out")
}

windowed() { # $1 header, then the script's lines
  local header=$1; shift
  {
    printf '#!%s\n%s\nsource %q\n' "$BASH" "$header" "$NDH_LOGGER_SH"
    printf '%s\n' "$@"
  } > "$script"
}

@test "traced before and after, untraced inside, the window named in the trace" {
  windowed 'set -euo pipefail' \
    'echo before' \
    'ndh::secret:begin "reads the token"' \
    's=VALUE-NOT-TO-TRACE; printf %s "$s" >/dev/null' \
    'ndh::secret:end' \
    'echo after'
  traced
  [ "$status" -eq 0 ]
  grep -qF "echo before" "$trace"
  grep -qF "secret window: reads the token" "$trace"
  refute grep -qF "VALUE-NOT-TO-TRACE" "$trace"
  grep -qF "secret window closed" "$trace"
  grep -qF "echo after" "$trace"
}

@test "an untraced script stays untraced after the window" {
  windowed 'set -euo pipefail' \
    'ndh::secret:begin "why"' \
    'ndh::secret:end' \
    'case $- in *x*) echo TRACED ;; *) echo UNTRACED ;; esac'
  run bash "$script"
  [ "$status" -eq 0 ]
  [ "$output" = UNTRACED ]
}

@test "nested windows: the inner end keeps the trace off, the outer end turns it back on" {
  windowed 'set -euo pipefail' \
    'ndh::secret:begin "outer"' \
    'ndh::secret:begin "inner"' \
    'ndh::secret:end' \
    'inner=VALUE-NOT-TO-TRACE' \
    'ndh::secret:end' \
    'echo after-outer'
  traced
  [ "$status" -eq 0 ]
  refute grep -qF "VALUE-NOT-TO-TRACE" "$trace"
  grep -qF "echo after-outer" "$trace"
}

@test "a child started inside a window sees NDH_LOGGER_XTRACE=0; end restores the previous value" {
  windowed 'set -euo pipefail' \
    'export NDH_LOGGER_XTRACE=1' \
    'ndh::secret:begin "why"' \
    'bash -c '\''echo "child=$NDH_LOGGER_XTRACE"'\''' \
    'ndh::secret:end' \
    'echo "after=$NDH_LOGGER_XTRACE"' \
    'unset NDH_LOGGER_XTRACE' \
    'ndh::secret:begin "why"' \
    'ndh::secret:end' \
    'echo "unset-after=${NDH_LOGGER_XTRACE-unset}"'
  run bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"child=0"* ]]
  [[ "$output" == *"after=1"* ]]
  [[ "$output" == *"unset-after=unset"* ]]
}

@test "a failure inside a window stops the script and traces no value, EXIT trap included" {
  windowed 'set -euo pipefail' \
    'trap '\''echo "exit sees $s"'\'' EXIT' \
    'ndh::secret:begin "why"' \
    's=VALUE-NOT-TO-TRACE' \
    'false' \
    'ndh::secret:end' \
    'echo REACHED-AFTER-FAILURE'
  traced
  [ "$status" -ne 0 ]
  [[ "$output" != *"REACHED-AFTER-FAILURE"* ]]
  refute grep -qF "VALUE-NOT-TO-TRACE" "$trace"
}

@test "end without begin fails" {
  windowed 'set -uo pipefail' \
    'ndh::secret:end; echo "rc=$?"'
  run bash "$script"
  [[ "$output" == *"no open window"* ]]
  [[ "$output" == *"rc=1"* ]]
}
