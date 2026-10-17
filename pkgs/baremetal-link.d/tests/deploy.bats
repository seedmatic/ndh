#!/usr/bin/env bats
# baremetal-link deploy, run the way the logger wrapper runs it (its real ndh::logger:command:invoke): a
# vz-host that answers on neither path, an install that does not complete, or a nudge identity that does
# not land each STOPS the deploy with its reason said — never "done" for what was not applied. ssh is a
# stub that records what it was asked and fails where the case says.

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
  T=$BATS_TEST_TMPDIR
  mkdir -p "$T/bin" "$T/keys"
  cat > "$T/bin/ssh" <<SSH
#!$BASH
printf '%s\n' "\$*" >> "\$T/ssh-calls"
case "\$*" in
  *" true")                 [ "\${STUB_PROBE:-ok}" = ok ] || exit 255 ;;
  *"sudo /bin/bash -s"*)
    payload=\$(cat)
    if [[ "\$payload" == *vz-nudge* ]]; then [ "\${STUB_NUDGE:-ok}" = ok ] || exit 1
    else [ "\${STUB_INSTALL:-ok}" = ok ] || exit 1; echo "\$payload" > "\$T/installed"; fi ;;
esac
exit 0
SSH
  sed -i "1a T=$T" "$T/bin/ssh"
  chmod +x "$T/bin/ssh"
  echo 'echo the install script' > "$T/install.sh"
  echo 'echo the uninstall script' > "$T/uninstall.sh"
  printf 'source %q\n' "$NDH_LOGGER_SH" > "$T/trampoline.sh"
  printf '#!%s\ncat >> "$1"\n' "$(command -v bash)" > "$T/sink"
  chmod +x "$T/sink"
  export LOGGER_CMD="$T/sink $T/wrapper.log"
  sed -e "s#@nixBashTrampoline@#$T/trampoline.sh#g" -e 's#@loggerTag@#test#g' -e "s#@ssh@#$T/bin/ssh#g" \
    -e "s#@timeout@#$(command -v timeout)#g" -e "s#@installScript@#$T/install.sh#g" \
    -e "s#@uninstallScript@#$T/uninstall.sh#g" -e 's#@vzHost@#vzhost.test#g' -e 's#@bootstrapHost@#lan.test#g' \
    -e "s#@systemKeysDir@#$T/keys#g" -e 's#@vzUser@#operator#g' \
    "$BATS_TEST_DIRNAME/../deploy.sh" > "$T/deploy"
}

@test "a vz-host that answers on neither path stops the deploy before anything is piped" {
  STUB_PROBE=fail run bash "$T/deploy"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED: neither vzhost.test nor lan.test answered — NOTHING was applied"* ]]
  refute grep -q 'sudo /bin/bash -s' "$T/ssh-calls"
}

@test "an install that does not complete stops the deploy, and no nudge identity is shipped" {
  echo private > "$T/keys/vz-nudge"; echo cert > "$T/keys/vz-nudge-cert.pub"
  STUB_INSTALL=fail run bash "$T/deploy"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED: install on vzhost.test did not complete — NOTHING was applied"* ]]
  [[ "$output" != *"shipping vz-nudge identity"* ]]
}

@test "a nudge identity that does not land is said, and fails the deploy" {
  echo private > "$T/keys/vz-nudge"; echo cert > "$T/keys/vz-nudge-cert.pub"
  STUB_NUDGE=fail run bash "$T/deploy"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED: the vz-nudge identity did not land on vzhost.test"* ]]
  [ -f "$T/installed" ]
}

@test "a complete deploy installs and ships the nudge identity" {
  echo private > "$T/keys/vz-nudge"; echo cert > "$T/keys/vz-nudge-cert.pub"
  run bash "$T/deploy"
  [ "$status" -eq 0 ]
  grep -q 'the install script' "$T/installed"
  [[ "$output" == *"shipping vz-nudge identity to vzhost.test"* ]]
}
