#!/usr/bin/env bats
# incus-cluster-join, run the way the logger wrapper runs it (its real ndh::logger:command:invoke): a
# bootstrap that is not a cluster, a preseed the joining member refuses, or a role that cannot be given
# STOPS the join with its reason said — never "joined" about a join that did not take. ssh is a stub that
# plays both incus daemons; jq and yq are real.

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
  mkdir -p "$T/bin"
  cat > "$T/bin/ssh" <<SSH
#!$BASH
host=""; for a in "\$@"; do case \$a in join.test|boot.test) host=\$a ;; esac; done
all="\$*"; cmd=\${all#*-- }
printf '%s: %s\n' "\$host" "\$cmd" >> "\$T/ssh-calls"
case "\$host:\$cmd" in
  "join.test:incus query /1.0")
    if [ -f "\$T/joined" ]; then echo '{"environment":{"server_clustered": true}}'; else echo '{"environment":{"server_clustered": false}}'; fi ;;
  "boot.test:incus query /1.0")
    [ "\${STUB_BOOTSTRAP:-cluster}" = cluster ] && echo '{"environment":{"server_clustered": true}}' || echo '{"environment":{"server_clustered": false}}' ;;
  "boot.test:incus config get cluster.https_address") echo boot.test:8443 ;;
  "join.test:incus storage list --format json") echo '[]' ;;
  "boot.test:incus cluster add --quiet join") echo 'Member join join token:'; printf 'eyFAKEtokenFAKEtokenFAKEtokenFAKEtoken0000\n' ;;
  "join.test:incus admin init --preseed")
    cat > /dev/null
    [ "\${STUB_PRESEED:-ok}" = ok ] || { echo "Error: failed to join cluster" >&2; exit 1; }
    touch "\$T/joined" ;;
  "boot.test:incus cluster role add join database-client") [ "\${STUB_ROLE:-ok}" = ok ] || exit 1 ;;
  "boot.test:incus cluster show join") echo 'roles: [database-client]' ;;
  "boot.test:incus cluster list") echo '| join | ONLINE |' ;;
  *) echo "stub ssh: unexpected \$host: \$cmd" >&2; exit 99 ;;
esac
SSH
  sed -i "1a T=$T" "$T/bin/ssh"
  chmod +x "$T/bin/ssh"
  printf 'source %q\n' "$NDH_LOGGER_SH" > "$T/trampoline.sh"
  printf '#!%s\ncat >> "$1"\n' "$(command -v bash)" > "$T/sink"
  chmod +x "$T/sink"
  export LOGGER_CMD="$T/sink $T/wrapper.log"
  sed -e "s#@nixBashTrampoline@#$T/trampoline.sh#g" -e 's#@loggerTag@#test#g' -e "s#@ssh@#$T/bin/ssh#g" \
    -e "s#@timeout@#$(command -v timeout)#g" -e "s#@jq@#$(command -v jq)#g" -e "s#@yq@#$(command -v yq)#g" \
    -e 's#@joiningMember@#join#g' -e 's#@bootstrapMember@#boot#g' -e 's#@joiningSsh@#join.test#g' \
    -e 's#@bootstrapSsh@#boot.test#g' -e 's#@joiningAddress@#join.test#g' -e 's#@poolName@#default#g' \
    -e 's#@poolSource@#tank/incus#g' \
    "$BATS_TEST_DIRNAME/../join.sh" > "$T/join"
}

@test "a bootstrap that is not a cluster stops the join before a token is minted" {
  STUB_BOOTSTRAP=standalone run bash "$T/join"
  [ "$status" -ne 0 ]
  [[ "$output" == *"boot is not a cluster yet"* ]]
  refute grep -q 'cluster add' "$T/ssh-calls"
}

@test "a preseed the joining member refuses stops the join, and no role is given" {
  STUB_PRESEED=fail run bash "$T/join"
  [ "$status" -ne 0 ]
  [[ "$output" == *"join REFUSED the preseed"* ]]
  refute grep -q 'role add' "$T/ssh-calls"
  [[ "$output" != *"joined and out of the raft"* ]]
}

@test "a role that cannot be given stops the join before it is reported" {
  STUB_ROLE=fail run bash "$T/join"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not give join the database-client role"* ]]
  [[ "$output" != *"joined and out of the raft"* ]]
}

@test "a join that takes is reported, with its role" {
  run bash "$T/join"
  [ "$status" -eq 0 ]
  [[ "$output" == *"join joined and out of the raft (roles: database-client)"* ]]
}

# The log sink is written by a process substitution, which may end after the script.
log_settled() {
  local i
  for i in $(seq 30); do
    grep -qE 'completed successfully|failed \(rc=' "$T/wrapper.log" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

@test "traced, a join that takes never writes its token to the log" {
  NDH_LOGGER_XTRACE=1 run bash "$T/join"
  [ "$status" -eq 0 ]
  log_settled
  grep -qF 'secret window: a join token is minted' "$T/wrapper.log"
  refute grep -qF 'eyFAKEtoken' "$T/wrapper.log"
  [[ "$output" != *eyFAKEtoken* ]]
}

@test "traced, a refused join never writes its token to the log" {
  STUB_PRESEED=fail NDH_LOGGER_XTRACE=1 run bash "$T/join"
  [ "$status" -ne 0 ]
  log_settled
  refute grep -qF 'eyFAKEtoken' "$T/wrapper.log"
  [[ "$output" != *eyFAKEtoken* ]]
}
