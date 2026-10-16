#!/usr/bin/env bats
# The operator's KnownHostsCommand, baked as ssh-keys.nix bakes it, against a throwaway authority
# directory: one @cert-authority line per authority public, for the fleet's names and nothing else.

NAMES="alpha,alpha.fabric.test,alpha.lan,alpha.local,alpha-nixos,nixos.alpha"

setup() {
  cd "$BATS_TEST_TMPDIR" || return
  mkdir ca.d
  # The stub runs the command the way the real ndh::logger:command:run does, without its log sinks.
  printf 'source "%s"\nndh::logger:command:run() { shift; ndh::logger:command:invoke "$@"; return "$NDH_LOGGER_COMMAND_RC"; }\n' \
    "$NDH_LOGGER_SH" >trampoline.sh
  # The build sandbox has no /usr/bin/env: the copy names this bash.
  sed -e "1s#^\#!/usr/bin/env bash#\#!$(command -v bash)#" \
    -e "s#@nixBashTrampoline@#$PWD/trampoline.sh#" -e "s#@caDir@#$PWD/ca.d#" -e "s#@hostNames@#$NAMES#" \
    "$KNOWN_HOSTS_COMMAND" >known-hosts-command
  chmod +x known-hosts-command
  ssh-keygen -q -t ed25519 -N '' -f fabric -C fabric
  ssh-keygen -q -t ed25519 -N '' -f fabric-old -C fabric-old
  cp fabric.pub ca.d/fabric-ca.pub
  cp fabric-old.pub ca.d/fabric-26-05-29-ca.pub
}

@test "one line per authority public, scoped to the fleet's names, never '*'" {
  run ./known-hosts-command
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *"@cert-authority $NAMES $(cut -d' ' -f1,2 fabric.pub)"* ]]
  [[ "$output" == *"@cert-authority $NAMES $(cut -d' ' -f1,2 fabric-old.pub)"* ]]
  [[ "$output" != *'@cert-authority *'* ]]
}

@test "every fleet name resolves to the authority, a host outside the fleet to nothing" {
  ./known-hosts-command >known_hosts
  for name in ${NAMES//,/ }; do
    run ssh-keygen -F "$name" -f known_hosts
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(cut -d' ' -f2 fabric.pub)"* ]]
  done
  for name in vzhost.alpha github.com alpha.example; do
    run ssh-keygen -F "$name" -f known_hosts
    [ "$status" -eq 1 ]
  done
}

@test "the host ssh asks about never widens the trust" {
  for args in "ORDER vzhost.alpha 192.0.2.1" "HOSTNAME vzhost.alpha" "vzhost.alpha 192.0.2.1"; do
    # shellcheck disable=SC2086
    run ./known-hosts-command $args
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" != *vzhost* ]]
  done
}

@test "only key files become trust lines" {
  : >ca.d/empty-ca.pub
  echo "not a key" >ca.d/bogus-ca.pub
  cp fabric-old.pub ca.d/rdp-host.pub
  run ./known-hosts-command
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" != *bogus* ]]
}

@test "no authority public, no line" {
  rm ca.d/*
  run ./known-hosts-command
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
