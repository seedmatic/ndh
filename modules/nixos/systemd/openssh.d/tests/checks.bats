#!/usr/bin/env bats
# The sshd post-flight check, run the way the logger wrapper runs it (its real ndh::logger:command:invoke):
# sshd not enabled or not active REFUSES (exit 1). `logger` and `systemctl` are stubs.

setup() {
  T=$BATS_TEST_TMPDIR
  mkdir -p "$T/bin" "$T/ca" "$T/state"
  # The checks' own journal lines.
  printf '#!%s\nprintf "%%s\\n" "$*" >> %q\n' "$(command -v bash)" "$T/journal" > "$T/bin/logger"
  printf '#!%s\ncase "$*" in\n  *UnitFileState*) echo "${STUB_UNIT_FILE_STATE:-enabled}" ;;\n  *ActiveState*) echo "${STUB_ACTIVE_STATE:-active}" ;;\n  *SubState*) echo running ;;\nesac\n' "$(command -v bash)" > "$T/bin/systemctl"
  chmod +x "$T/bin/logger" "$T/bin/systemctl"
  export PATH="$T/bin:$PATH"
  # The wrapper's own lines go to a file sink, apart from the checks' journal.
  printf '#!%s\ncat >> "$1"\n' "$(command -v bash)" > "$T/sink"
  chmod +x "$T/sink"
  export LOGGER_CMD="$T/sink $T/wrapper.log"
  printf 'source %q\n' "$NDH_LOGGER_SH" > "$T/trampoline.sh"
}

render() { # $1 script name, then sed expressions
  local name=$1; shift
  sed -e "s#@nixBashTrampoline@#$T/trampoline.sh#" -e 's#@logTag@#test#' "$@" \
    "$BATS_TEST_DIRNAME/../$name" > "$T/$name"
}

@test "sshd not enabled, or not active, REFUSES" {
  render sshd-autostart-check.sh
  STUB_UNIT_FILE_STATE=disabled run bash "$T/sshd-autostart-check.sh"
  [ "$status" -eq 1 ]
  grep -q 'unexpected sshd unit file state: disabled' "$T/journal"
  STUB_ACTIVE_STATE=failed run bash "$T/sshd-autostart-check.sh"
  [ "$status" -eq 1 ]
  grep -q 'sshd not active after contributed target: ActiveState=failed' "$T/journal"
  run bash "$T/sshd-autostart-check.sh"
  [ "$status" -eq 0 ]
  grep -q 'sshd autostart check passed' "$T/journal"
}
