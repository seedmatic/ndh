#!/usr/bin/env bats
# The sshd post-flight checks, each run the way the logger wrapper runs it (its real
# ndh::logger:command:invoke): a host key that cannot be read is REPORTED, never taken as aligned and never
# an abort; sshd not enabled or not active REFUSES (exit 1); the authorized-keys check reports every
# finding and never blocks sshd (exit 0). `logger` and `systemctl` are stubs; ssh-keygen and yq are real.

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

hostkey_check() {
  render hostkey-enrollment-check.sh -e "s#@userPrivateSourceDir@#$T/ca#" -e "s#@userCaSourceDir@#$T/ca#" \
    -e "s#@systemHostKeyPub@#$T/host.pub#" -e 's#@clientKeyName@#id#' -e "s#^STATE_DIR=.*#STATE_DIR=$T/state#"
  run bash "$T/hostkey-enrollment-check.sh"
}
state() { yq -r ".$1" "$T/state/hostkey-enrollment-state.yaml"; }
newkey() { mkdir -p "$T/keys"; ssh-keygen -q -t ed25519 -N '' -C test -f "$T/keys/$1" && cp "$T/keys/$1.pub" "$2"; }

@test "an expected host key that cannot be read is REPORTED as unavailable, never passed" {
  echo 'this is not a public key' > "$T/ca/id.pub"
  newkey host "$T/host.pub"
  hostkey_check
  [ "$status" -eq 0 ]
  [ "$(state reason)" = fingerprint_unavailable ]
  [ "$(state required)" = true ]
  grep -q 'enrollment required: reason=fingerprint_unavailable' "$T/journal"
}

@test "a host key that differs from the secret's is a mismatch; the same one is aligned" {
  newkey a "$T/ca/id.pub"
  newkey b "$T/host.pub"
  hostkey_check
  [ "$(state reason)" = hostkey_mismatch ]
  cp "$T/ca/id.pub" "$T/host.pub"
  hostkey_check
  [ "$status" -eq 0 ]
  [ "$(state reason)" = aligned ]
  [ "$(state required)" = false ]
}

@test "a missing expected key is said as such" {
  newkey host "$T/host.pub"
  hostkey_check
  [ "$(state reason)" = missing_expected_secret_key ]
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

authkeys_check() {
  render authorized-keys-check.sh -e "s#@authorizedKeysFile@#$T/authorized_keys#" \
    -e "s#@expectedPublicKeyFile@#$T/expected.pub#" -e 's#@profileUserName@#tester#'
  run bash "$T/authorized-keys-check.sh"
}

@test "the authorized-keys check reports every finding and never blocks sshd" {
  newkey k "$T/expected.pub"
  newkey other "$T/authorized_keys"
  authkeys_check
  [ "$status" -eq 0 ]
  grep -q 'authorized key mismatch' "$T/journal"
  grep -q 'completed with 1 finding' "$T/journal"
  rm "$T/authorized_keys"
  authkeys_check
  [ "$status" -eq 0 ]
  grep -q 'missing authorized keys file' "$T/journal"
}

@test "an expected key file of many lines is read, and a present key passes" {
  newkey k "$T/expected.pub"
  seq 1 5000 | sed 's/^/# filler /' >> "$T/expected.pub"
  cp "$T/expected.pub" "$T/authorized_keys"
  authkeys_check
  [ "$status" -eq 0 ]
  grep -q 'authorized key check passed' "$T/journal"
}

reload() {
  render sshd-host-identity-reload.sh -e "s#@hostKeySource@#$T/keys/extracted#" \
    -e "s#@hostKeyPublicSource@#$T/keys/extracted.pub#" -e "s#@systemHostKey@#$T/etc/ssh_host_ed25519_key#" \
    -e "s#@hostCertificatePath@#$T/cert.pub#"
  run bash "$T/sshd-host-identity-reload.sh"
}

@test "a changed host key restarts tailscaled once; an unchanged one, or no tailscaled, does not" {
  printf '#!%s\nprintf "%%s\\n" "$*" >> %q\ncase "$*" in\n  *LoadState*) echo "${STUB_LOAD_STATE:-loaded}" ;;\n  is-failed*) exit 1 ;;\nesac\n' \
    "$(command -v bash)" "$T/systemctl.calls" > "$T/bin/systemctl"
  mkdir -p "$T/etc"
  extracted() { newkey "$1" "$T/keys/extracted.pub" && cp "$T/keys/$1" "$T/keys/extracted"; }
  extracted first
  reload
  [ "$status" -eq 0 ]
  cmp -s "$T/keys/extracted" "$T/etc/ssh_host_ed25519_key"
  [ "$(grep -c '^try-restart --no-block tailscaled.service$' "$T/systemctl.calls")" -eq 1 ]
  grep -q 'tailscaled restart queued' "$T/journal"
  grep -q '^try-restart --no-block sshd.service$' "$T/systemctl.calls"

  : > "$T/systemctl.calls"
  reload
  [ "$status" -eq 0 ]
  [ "$(grep -c tailscaled "$T/systemctl.calls")" -eq 0 ]
  grep -q '^try-restart --no-block sshd.service$' "$T/systemctl.calls"

  extracted second
  : > "$T/systemctl.calls"
  STUB_LOAD_STATE=not-found reload
  [ "$status" -eq 0 ]
  cmp -s "$T/keys/extracted" "$T/etc/ssh_host_ed25519_key"
  [ "$(grep -c "^try-restart --no-block tailscaled" "$T/systemctl.calls")" -eq 0 ]
}
