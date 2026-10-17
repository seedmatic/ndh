#!/usr/bin/env bats
#
# ndh-vz-recover against stubbed tart and open, then through a REAL sshd on loopback serving the package's
# own authorized_keys options (AUTHORIZED_OPTIONS, with @COMMAND@ for the program's path): the client's
# words select one of four verbs or are refused, and no request ever yields a shell.

bats_require_minimum_version 1.5.0

setup() {
  : "${AUTHORIZED_OPTIONS:?the vz-recover key's authorized_keys options}"
  T=$BATS_TEST_TMPDIR
  export HOME=$T/home
  mkdir -p "$HOME" "$T/bin"
  # The stub tart records its argv, prints what a guest would, and fails a probe for a VM without an agent.
  cat >"$T/bin/tart" <<EOF
#!$BASH
printf '%s\n' "\$*" >>"$T/tart.argv"
echo GUEST-OUTPUT
if [[ \$1 == exec && \$3 == */true && ! -e "$T/agent-\$2" ]]; then exit 1; fi
exit "\$(cat "$T/tart.exit" 2>/dev/null || echo 0)"
EOF
  cat >"$T/bin/open" <<EOF
#!$BASH
printf '%s\n' "\$*" >>"$T/open.argv"
EOF
  chmod +x "$T/bin/tart" "$T/bin/open"
  {
    printf '#!%s\nset -o errexit -o nounset -o pipefail\n' "$BASH"
    printf 'vms=(nerd-nixos nikopol)\nkinds=(nixos darwin)\n'
    printf 'tart=%s\ntimeout=%s\nopen=%s\n' "$T/bin/tart" "$(command -v timeout)" "$T/bin/open"
    cat "$BATS_TEST_DIRNAME/../ndh-vz-recover.sh"
  } >"$T/ndh-vz-recover"
  chmod +x "$T/ndh-vz-recover"
  log=$HOME/Library/Logs/ndh-vz-recover.log
}

teardown() {
  [ -f "$T/sshd.pid" ] && kill "$(cat "$T/sshd.pid")" 2>/dev/null || true
}

call() {
  SSH_ORIGINAL_COMMAND=$1 SSH_CLIENT="192.0.2.7 50000 22" run --separate-stderr "$T/ndh-vz-recover"
  printf 'status %s\nstdout %s\nstderr %s\n--- tart\n%s\n--- log\n%s\n' "$status" "$output" "$stderr" \
    "$(cat "$T/tart.argv" 2>/dev/null)" "$(cat "$log" 2>/dev/null)"
}

@test "list probes each VM's guest agent with its own true, and logs one line" {
  touch "$T/agent-nerd-nixos"
  call list
  [ "$status" -eq 0 ]
  [ "$output" = $'nerd-nixos agent-up\nnikopol no-agent' ]
  [ "$(<"$T/tart.argv")" = $'exec nerd-nixos /run/current-system/sw/bin/true\nexec nikopol /usr/bin/true' ]
  [[ $(<"$log") =~ ^[0-9T:-]+Z\ 192\.0\.2\.7\ list\ -\ 0$ ]]
}

@test "rollback runs the previous generation's switch in the guest, by kind" {
  call "rollback nerd-nixos"
  [ "$status" -eq 0 ]
  call "rollback nikopol"
  [ "$status" -eq 0 ]
  [ "$(<"$T/tart.argv")" = "exec nerd-nixos /run/current-system/sw/bin/nixos-rebuild switch --rollback
exec nikopol /usr/bin/sudo -n /run/current-system/sw/bin/darwin-rebuild switch --rollback" ]
}

@test "restart-access restarts sshd and tailscaled on NixOS, tailscaled alone on darwin" {
  call "restart-access nerd-nixos"
  [ "$status" -eq 0 ]
  call "restart-access nikopol"
  [ "$status" -eq 0 ]
  [ "$(<"$T/tart.argv")" = "exec nerd-nixos /run/current-system/sw/bin/systemctl restart sshd.service tailscaled.service
exec nikopol /usr/bin/sudo -n /bin/launchctl kickstart -k system/com.tailscale.tailscaled" ]
}

@test "restart stops the VM, then opens its launcher in Terminal, even when the stop fails" {
  mkdir -p "$HOME/.tart/vms/nikopol"
  printf '#!/bin/sh\n' >"$HOME/.tart/vms/nikopol/nikopol.sh"
  chmod +x "$HOME/.tart/vms/nikopol/nikopol.sh"
  echo 1 >"$T/tart.exit"
  call "restart nikopol"
  [ "$status" -eq 0 ]
  [ "$(<"$T/tart.argv")" = "stop --timeout 60 nikopol" ]
  [ "$(<"$T/open.argv")" = "-a Terminal $HOME/.tart/vms/nikopol/nikopol.sh" ]
  grep -q ' restart nikopol stop=1$' "$log"
  grep -q ' restart nikopol 0$' "$log"
}

@test "restart without the VM's launcher stops nothing and refuses with 66" {
  call "restart nerd-nixos"
  [ "$status" -eq 66 ]
  [ ! -e "$T/tart.argv" ] && [ ! -e "$T/open.argv" ]
  grep -q ' restart nerd-nixos 66 no-launcher$' "$log"
}

@test "a guest command's failure is the call's status, and is logged" {
  echo 3 >"$T/tart.exit"
  call "rollback nerd-nixos"
  [ "$status" -eq 3 ]
  grep -q ' rollback nerd-nixos 3$' "$log"
}

@test "anything outside the vocabulary is refused with 64, runs nothing, and is logged" {
  for words in "" "bash" "list nerd-nixos" "rollback" "rollback nerd-nixos now" "rollback other" \
    "rollback nerd-nixos;id" "rollback  nerd-nixos" "list " "Rollback nerd-nixos" "internal-sftp" \
    "/usr/libexec/sftp-server" $'rollback nerd-nixos\n' "rollback \$(id)"; do
    call "$words"
    [ "$status" -eq 64 ]
  done
  [ ! -e "$T/tart.argv" ] && [ ! -e "$T/open.argv" ]
  [ "$(grep -c ' refused 64' "$log")" -eq 14 ]
  grep -q ' refused 64 rollback nerd-nixos?$' "$log"
}

@test "a second call while one runs is refused with 75 and leaves the lock to its holder" {
  mkdir -p "$HOME/.local/state/ndh-vz-recover/lock"
  call "rollback nerd-nixos"
  [ "$status" -eq 75 ]
  [ ! -e "$T/tart.argv" ]
  [ -d "$HOME/.local/state/ndh-vz-recover/lock" ]
  grep -q ' rollback nerd-nixos 75 busy$' "$log"
}

@test "a call releases the lock, and list takes none" {
  call "restart-access nerd-nixos"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/state/ndh-vz-recover/lock" ]
  mkdir -p "$HOME/.local/state/ndh-vz-recover/lock"
  call list
  [ "$status" -eq 0 ]
}

@test "the log is 0600 and carries no output" {
  call "rollback nerd-nixos"
  [[ $output == *GUEST-OUTPUT* ]]
  [ "$(stat -c %a "$log" 2>/dev/null || stat -f %Lp "$log")" = 600 ]
  ! grep -q GUEST-OUTPUT "$log"
}

# Starts a real sshd authorizing user.pub with exactly the package's options, the program as the command.
serve() {
  cd "$T"
  for n in host user; do ssh-keygen -q -t ed25519 -N '' -f "$n" -C "$n"; done
  port=$((20000 + RANDOM % 20000))
  # The nix sandbox's passwd gives the build user the shell /noshell, which sshd refuses before any key; it
  # runs the forced command through this one, the bats bash.
  printf '%s:x:%s:%s::%s:%s\n' "$(id -un)" "$(id -u)" "$(id -g)" "$HOME" "$BASH" >passwd
  printf '%s:x:%s:\n' "$(id -gn)" "$(id -g)" >group
  printf '%s %s\n' "${AUTHORIZED_OPTIONS//@COMMAND@/$T/ndh-vz-recover}" "$(<user.pub)" >authorized_keys
  cat >sshd_config <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $T/host
AuthorizedKeysFile $T/authorized_keys
StrictModes no
PidFile $T/sshd.pid
Subsystem sftp internal-sftp
EOF
  LD_PRELOAD="${NSS_WRAPPER_LIB:?}" NSS_WRAPPER_PASSWD="$T/passwd" NSS_WRAPPER_GROUP="$T/group" \
    "$(command -v sshd)" -f "$T/sshd_config" -E "$T/sshd.log"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s sshd.pid ] && break; sleep 0.2; done
}

ssh_as_user() {
  run ssh -F /dev/null -p "$port" -i "$T/user" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null "$@"
  printf 'ssh: %s\n--- sshd.log\n%s\n' "$output" "$(cat "$T/sshd.log" 2>/dev/null)"
}

@test "the options are restrict and the program as the forced command, exactly" {
  [ "$AUTHORIZED_OPTIONS" = 'restrict,command="@COMMAND@"' ]
}

@test "through sshd: a verb reaches the program, which runs it" {
  serve
  ssh_as_user localhost "rollback nerd-nixos" </dev/null
  [ "$status" -eq 0 ]
  [ "$(<"$T/tart.argv")" = "exec nerd-nixos /run/current-system/sw/bin/nixos-rebuild switch --rollback" ]
}

@test "through sshd: a shell command, a login and the sftp subsystem all meet the program's refusal" {
  serve
  ssh_as_user localhost "touch $T/shell-ran" </dev/null
  [ "$status" -eq 64 ]
  ssh_as_user -tt localhost </dev/null
  [ "$status" -eq 64 ]
  printf 'ls\n' >batch
  run sftp -q -b batch -F /dev/null -P "$port" -i "$T/user" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null localhost
  [ "$status" -ne 0 ]
  [ ! -e "$T/shell-ran" ] && [ ! -e "$T/tart.argv" ]
  [ "$(grep -c ' refused 64' "$log")" -eq 3 ]
}
