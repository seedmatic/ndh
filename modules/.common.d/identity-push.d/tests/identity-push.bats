#!/usr/bin/env bats
#
# ndh-identity-push and ndh-identity-receive on their REAL path, the keys generated here. Only the outside
# world is stubbed, first on PATH: route and ifconfig (the seat's link), ssh-keyscan (what the machine's
# sshd serves) and ssh, which checks the pinning options and runs the real receive against a temp root.
# The seat's own push goes through a sudo stub to a second receive, configured as the darwin seat's. The
# guest's receive takes the sshfs key (it mounts sshfs); a third receive is a guest that does not. The other
# metalspace's guest and darwin host, reached on the home LAN, each have their own receive, chosen by address.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  # The stubs run under the bats bash itself: the darwin build sandbox refuses to exec /usr/bin/env.
  shebang="#!$BASH"
  mkdir -p "$t/bin" "$t/tmp" "$t/root/var/lib/sops-nix" "$t/seat-root"
  here="${BATS_TEST_DIRNAME}/.."
  key() { ssh-keygen -q -t ed25519 -N "${2:-}" -C "$1" -f "$t/$1"; }
  key machine
  key seat
  key served
  key operator
  key sshfs

  keyFile="$t/root/var/lib/sops-nix/bioskop-nixos.age"
  hostKeyFile="$t/root/var/lib/ndh/host-key/ssh_host_ed25519_key"
  sshfsKeyFile="$t/root/var/lib/ndh/sshfs/id_ed25519"
  # keys.yaml's records, as a receive bakes them: the test keys are the recorded ones.
  recorded() { # [host key file] [sshfs key file] [access point file]
    printf 'recordedHostKey=%q recordedSshfsKey=%q recordedAccessPoint=%q\n' \
      "$(cut -d' ' -f1,2 "${1:-$t/machine.pub}" 2>/dev/null)" "$(cut -d' ' -f1,2 "${2:-$t/sshfs.pub}" 2>/dev/null)" \
      "$(cut -d' ' -f1,2 "${3:-$t/seat.pub}" 2>/dev/null)"
  }
  guest_receive() { # <sshfsKeyFile> [machine root]
    printf 'set -euo pipefail\n'
    recorded
    printf 'machine=%s keyFile=%q hostKeyFile=%q sshfsKeyFile=%q served=%q owner="" maxBytes=8192\n' \
      "${2:-bioskop-nixos}" "${3:-$keyFile}" "${4:-$hostKeyFile}" "$1" "$t/served.pub"
    cat "$here/ndh-identity-receive.sh"
  }
  guest_receive "$sshfsKeyFile" >"$t/bin/ndh-identity-receive"
  guest_receive "" >"$t/no-sshfs-receive"
  nnRoot="$t/nikopol-nixos-root/var/lib"
  guest_receive "$nnRoot/ndh/sshfs/id_ed25519" nikopol-nixos "$nnRoot/sops-nix/nikopol-nixos.age" \
    "$nnRoot/ndh/host-key/ssh_host_ed25519_key" >"$t/nikopol-nixos-receive"
  darwinHostKeyFile="$t/nikopol-root/var/lib/ndh/host-key/ssh_host_ed25519_key"
  {
    printf 'set -euo pipefail\n'
    recorded
    printf 'machine=nikopol keyFile="" hostKeyFile=%q sshfsKeyFile="" served=%q owner="" maxBytes=8192\n' \
      "$darwinHostKeyFile" "$t/served.pub"
    cat "$here/ndh-identity-receive.sh"
  } >"$t/darwin-receive"
  mkdir -p "$nnRoot/sops-nix"
  chmod +x "$t/bin/ndh-identity-receive" "$t/no-sshfs-receive" "$t/nikopol-nixos-receive" "$t/darwin-receive"
  seatHostKeyFile="$t/seat-root/var/lib/ndh/host-key/ssh_host_ed25519_key"
  {
    printf 'set -euo pipefail\n'
    recorded
    printf 'machine=bioskop keyFile="" hostKeyFile=%q sshfsKeyFile="" served=%q owner="" maxBytes=8192\n' \
      "$seatHostKeyFile" "$t/served.pub"
    cat "$here/ndh-identity-receive.sh"
  } >"$t/seat-receive"
  chmod +x "$t/seat-receive"
  {
    printf 'set -euo pipefail\n'
    printf 'seat=bioskop maxBytes=8192\n'
    printf 'declare -A targetKind=([bioskop-nixos]=nixos [nikopol-nixos]=nixos [nikopol]=darwin)\n'
    printf 'declare -A targetAddress=([bioskop-nixos]=172.16.8.1 [nikopol-nixos]=192.168.1.34 [nikopol]=192.168.1.33)\n'
    printf 'declare -A targetLocal=([bioskop-nixos]=172.16.8.2 [nikopol-nixos]=192.168.1.129 [nikopol]=192.168.1.129)\n'
    printf 'machine="" kind="" address="" localAddress=""\n'
    printf 'sshUser=nxmatic sshKey=%q sshCert=%q ttyIn=%q\n' "$t/operator" "$t/operator-cert.pub" "$t/typed"
    printf 'localSudo=%q localReceive=%q\n' "$t/bin/sudo" "$t/seat-receive"
    cat "$here/ndh-identity-push.sh"
  } >"$t/push"
  ssh-keygen -l -E sha256 -f "$t/served.pub" | awk '{ print $2 }' >"$t/typed"

  cat >"$t/bin/route" <<EOF
$shebang
printf '   route to: %s\n  interface: en9\n' "\${@: -1}"
EOF
  cat >"$t/bin/ifconfig" <<EOF
$shebang
printf 'en9: flags=8963<UP>\n\tinet %s netmask 0xfffffffc\n' "\${STUB_LOCAL:-172.16.8.2}"
EOF
  cat >"$t/bin/ssh-keyscan" <<EOF
$shebang
printf '# 172.16.8.1:22 SSH-2.0-OpenSSH\n172.16.8.1 %s\n' "\$(cut -d' ' -f1,2 "${STUB_SERVED:-$t/served.pub}")"
EOF
  cat >"$t/bin/ssh" <<EOF
$shebang
# The pinning is checked, not trusted: ONLY the throwaway known_hosts, holding the served key.
args=" \$* "
for o in "-F /dev/null " UserKnownHostsFile= "GlobalKnownHostsFile=/dev/null " "StrictHostKeyChecking=yes " \
  "IdentityAgent=none " "BatchMode=yes " "PasswordAuthentication=no " "KbdInteractiveAuthentication=no "; do
  [[ \$args == *"\$o"* ]] || { echo "ssh stub: missing -o \$o" >&2; exit 97; }
done
kh="\${args#* UserKnownHostsFile=}"; kh="\${kh%% *}"
grep -qF "\$(cut -d' ' -f2 "$t/served.pub")" "\$kh" || { echo "ssh stub: host key not pinned" >&2; exit 98; }
echo "\$*" >>"$t/ssh.log"
# The receive the address names, and the sudo and fixed path its kind is reached by.
case "\${@: -2:1}" in
  192.168.1.33) rcv="$t/darwin-receive" sudo=/usr/bin/sudo ;;
  192.168.1.34) rcv="$t/nikopol-nixos-receive" sudo=/run/wrappers/bin/sudo ;;
  *) rcv=ndh-identity-receive sudo=/run/wrappers/bin/sudo ;;
esac
case "\${@: -1}" in
  "\$sudo -n /run/current-system/sw/bin/ndh-identity-receive --accept")
    if [[ -n \${STUB_TAMPER:-} ]]; then "\$rcv" --accept | sed 's/^age .*/age age1tampered/'; else exec "\$rcv" --accept; fi ;;
  "\$sudo -n /run/current-system/sw/bin/ndh-identity-reload") touch "$t/reloaded"; echo "[ndh-identity-reload] restarted" ;;
  *) echo "ssh stub: unexpected \${@: -1}" >&2; exit 99 ;;
esac
EOF
  cat >"$t/bin/sudo" <<EOF
$shebang
[[ \$1 == -n ]] || { echo "sudo stub: not -n" >&2; exit 96; }
shift
echo "\$*" >>"$t/sudo.log"
exec "\$@"
EOF
  chmod +x "$t/bin/"*
}

push() { TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash "$t/push" "$@" 3<"$t/machine" 4<"$t/seat" 5<"$t/sshfs"; }
nothing_placed() { [ ! -e "$keyFile" ] && [ ! -e "$hostKeyFile" ] && [ ! -e "$sshfsKeyFile" ]; }
no_private_in() { ! grep -rqE 'AGE-SECRET-KEY|PRIVATE KEY' "$@"; }

@test "a push places the three identities, 0400, checked by their publics, then reloads" {
  push bioskop-nixos
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$keyFile")" = 400 ]
  [ "$(stat -c %a "$hostKeyFile")" = 400 ]
  [ "$(stat -c %a "$sshfsKeyFile")" = 400 ]
  [ "$(stat -c %a "$(dirname "$sshfsKeyFile")")" = 700 ]
  [ "$(ssh-keygen -y -f "$sshfsKeyFile" | cut -d' ' -f1,2)" = "$(cut -d' ' -f1,2 "$t/sshfs.pub")" ]
  [[ $output == *"next: commit ndh.sshfs.ownKey = true for bioskop-nixos"* ]]
  # The age identity is the SEAT's host key converted; the host key is the machine's own.
  [ "$(age-keygen -y "$keyFile")" = "$(ssh-to-age -i "$t/seat.pub")" ]
  [ "$(ssh-keygen -y -f "$hostKeyFile" | cut -d' ' -f1,2)" = "$(cut -d' ' -f1,2 "$t/machine.pub")" ]
  [ -e "$t/reloaded" ]
  # Both sessions ran with the user's ssh config ignored.
  [ "$(grep -c -- '-F /dev/null ' "$t/ssh.log")" -eq 2 ]
  [[ $output != *AGE-SECRET-KEY* && $output != *"PRIVATE KEY"* ]]
  no_private_in "$t/tmp" "$t/ssh.log"
  [ -z "$(find "$t/root" -name '.ndh-identity.*')" ]
}

@test "a fingerprint other than the one served is refused, and nothing is sent" {
  echo "SHA256:$(printf 'x%.0s' {1..43})" >"$t/typed"
  push bioskop-nixos
  [ "$status" -eq 1 ]
  [[ $output == *"not the SHA256:"*"read at the console"* ]]
  [ ! -e "$t/ssh.log" ]
  nothing_placed
}

@test "a typed fingerprint is compared in its canonical form only" {
  echo "MD5:aa:bb" >"$t/typed"
  push bioskop-nixos
  [ "$status" -eq 1 ]
  [[ $output == *"not a SHA256 fingerprint"* ]]
  [ ! -e "$t/ssh.log" ]
}

@test "an address not reached through the seat's own link is refused, nothing sent" {
  STUB_LOCAL=192.168.1.129 push bioskop-nixos
  [ "$status" -eq 1 ]
  [[ $output == *"not reached through bioskop's own link"* ]]
  [ ! -e "$t/ssh.log" ]
}

@test "the keyring seat pushes to the inventory's machines only" {
  push elsewhere
  [ "$status" -eq 1 ]
  [[ $output == *"pushes to the inventory's machines"*"not to elsewhere"* ]]
  [ ! -e "$t/ssh.log" ]
}

@test "the other metalspace's guest gets its three identities over the home LAN, on the seat's own link" {
  STUB_LOCAL=192.168.1.129 push nikopol-nixos
  [ "$status" -eq 0 ]
  [ "$(ssh-keygen -y -f "$nnRoot/ndh/host-key/ssh_host_ed25519_key" | cut -d' ' -f1,2)" = "$(cut -d' ' -f1,2 "$t/machine.pub")" ]
  [ "$(age-keygen -y "$nnRoot/sops-nix/nikopol-nixos.age")" = "$(ssh-to-age -i "$t/seat.pub")" ]
  [ -e "$nnRoot/ndh/sshfs/id_ed25519" ]
  [ -e "$t/reloaded" ]
  grep -q '192.168.1.34 /run/wrappers/bin/sudo -n /run/current-system/sw/bin/ndh-identity-receive --accept$' "$t/ssh.log"
  nothing_placed
}

@test "a home-LAN target not reached on the seat's own link is refused, nothing sent" {
  push nikopol-nixos
  [ "$status" -eq 1 ]
  [[ $output == *"192.168.1.34 is not reached through bioskop's own link"* ]]
  [ ! -e "$t/ssh.log" ]
}

# fd 4 and fd 5 closed, as a darwin host's push has them.
push_darwin() { TMPDIR="$t/tmp" PATH="$t/bin:$PATH" STUB_LOCAL=192.168.1.129 run bash "$t/push" nikopol 3<"$t/machine" 4<&- 5<&-; }

@test "a darwin host gets its host key only, by sudo -n and the receive's fixed path, and nothing reloads" {
  push_darwin
  [ "$status" -eq 0 ]
  [ "$(ssh-keygen -y -f "$darwinHostKeyFile" | cut -d' ' -f1,2)" = "$(cut -d' ' -f1,2 "$t/machine.pub")" ]
  [ "$(stat -c %a "$darwinHostKeyFile")" = 400 ]
  grep -q '192.168.1.33 /usr/bin/sudo -n /run/current-system/sw/bin/ndh-identity-receive --accept$' "$t/ssh.log"
  [ "$(wc -l <"$t/ssh.log")" -eq 1 ]
  [ ! -e "$t/reloaded" ]
  [[ $output == *"next: commit ndh.hostKey.own = true for nikopol, then switch it, locally"* ]]
  [[ $output != *"age identity"* ]]
  no_private_in "$t/tmp" "$t/ssh.log"
}

@test "a darwin host refuses an access point key on fd 4 or an sshfs key on fd 5, and nothing is sent" {
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" STUB_LOCAL=192.168.1.129 run bash "$t/push" nikopol 3<"$t/machine" 4<"$t/seat" 5<&-
  [ "$status" -eq 1 ]
  [[ $output == *"nikopol takes its host key only, on fd 3: close fd 4"* ]]
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" STUB_LOCAL=192.168.1.129 run bash "$t/push" nikopol 3<"$t/machine" 4<&- 5<"$t/sshfs"
  [ "$status" -eq 1 ]
  [[ $output == *"nikopol takes its host key only, on fd 3: close fd 5"* ]]
  [ ! -e "$t/ssh.log" ] && [ ! -e "$darwinHostKeyFile" ]
}

@test "a passphrase-protected key on fd 4 is refused before anything is sent" {
  ssh-keygen -q -t ed25519 -N secret -C seat2 -f "$t/seat2"
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash "$t/push" bioskop-nixos 3<"$t/machine" 4<"$t/seat2" 5<"$t/sshfs"
  [ "$status" -eq 1 ]
  [[ $output == *"fd 4 is not an unencrypted ed25519"* ]]
  [ ! -e "$t/ssh.log" ]
}

@test "publics that differ after the write stop the push before the reload" {
  STUB_TAMPER=1 push bioskop-nixos
  [ "$status" -eq 1 ]
  [[ $output == *"NOT reloaded"* ]]
  [ ! -e "$t/reloaded" ]
}

frame() { # <machine> [sshfs key file] — a valid frame for MACHINE, with the sshfs key by default
  printf 'ndh-identity/1 %s\n%s\n%s\n' "$1" "$(ssh-to-age -private-key -i "$t/seat")" "$(<"$t/machine")"
  [[ ${2-$t/sshfs} == "" ]] || printf '%s\n' "$(<"${2-$t/sshfs}")"
  printf 'end\n'
}
receive() { PATH="$t/bin:$PATH" run ndh-identity-receive --accept; }

@test "receive: a frame addressed to another machine writes nothing" {
  receive < <(frame nikopol-nixos)
  [ "$status" -eq 1 ]
  [[ $output == *"not addressed to bioskop-nixos — refused, nothing written"* ]]
  nothing_placed
}

@test "receive: a frame over the size bound writes nothing" {
  receive < <(frame bioskop-nixos; head -c 9000 /dev/zero | tr '\0' A)
  [ "$status" -eq 1 ]
  [[ $output == *"exceeds 8192 bytes"* ]]
  nothing_placed
}

@test "receive: a damaged host key writes nothing, and the identity in place is untouched" {
  echo previous >"$keyFile"
  receive < <(frame bioskop-nixos | sed '4s/^./!/')
  [ "$status" -eq 1 ]
  [[ $output == *"refused, nothing written"* ]]
  [ "$(<"$keyFile")" = previous ]
  [ ! -e "$hostKeyFile" ]
  [ -z "$(find "$t/root" -name '.ndh-identity.*')" ]
}

@test "receive: an age identity that does not load writes nothing" {
  receive < <(frame bioskop-nixos | sed "2s/.*/AGE-SECRET-KEY-1$(printf 'Q%.0s' {1..58})/")
  [ "$status" -eq 1 ]
  nothing_placed
  [[ $output != *AGE-SECRET-KEY* ]]
}

@test "receive at the console prints the fingerprint its sshd serves" {
  PATH="$t/bin:$PATH" run ndh-identity-receive
  [ "$status" -eq 0 ]
  [[ $output == *"fingerprint  $(<"$t/typed")"* ]]
}

@test "under bash -x, the push says xtrace is off and traces no private" {
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash -x "$t/push" bioskop-nixos 3<"$t/machine" 4<"$t/seat" 5<"$t/sshfs"
  [ "$status" -eq 0 ]
  [[ $output == *"[xtrace-guard] xtrace disabled"* ]]
  [[ $output != *AGE-SECRET-KEY* && $output != *"PRIVATE KEY"* ]]
}

seat_push() { # [fd 4 source] — the seat's own push, every network tool failing if called
  local c
  for c in route ifconfig ssh-keyscan ssh; do
    printf '%s\necho %s >>%q\nexit 95\n' "$shebang" "$c" "$t/network.log" >"$t/bin/$c"
  done
  if [[ -n ${1:-} ]]; then
    TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash "$t/push" bioskop 3<"$t/machine" 4<"$1"
  else
    TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash "$t/push" bioskop 3<"$t/machine" 4<&- 5<&-
  fi
}

@test "the seat's push places its host key only, locally, checked by its public, and says what comes next" {
  seat_push
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$seatHostKeyFile")" = 400 ]
  [ "$(ssh-keygen -y -f "$seatHostKeyFile" | cut -d' ' -f1,2)" = "$(cut -d' ' -f1,2 "$t/machine.pub")" ]
  [ "$(find "$t/seat-root" -type f | wc -l)" -eq 1 ]
  [ "$(<"$t/sudo.log")" = "$t/seat-receive --accept" ]
  [ ! -e "$t/network.log" ]
  [[ $output != *"The fingerprint"* ]]
  [[ $output == *"next: commit ndh.hostKey.own = true for bioskop, then switch"* ]]
  [[ $output == *"ssh-keygen -R <name>"* ]]
  [[ $output != *AGE-SECRET-KEY* && $output != *"PRIVATE KEY"* ]]
  nothing_placed
}

@test "the seat's push refuses a key on fd 4, and sends nothing" {
  seat_push "$t/seat"
  [ "$status" -eq 1 ]
  [[ $output == *"takes its host key only, on fd 3"* ]]
  [ ! -e "$t/sudo.log" ]
  [ ! -e "$t/network.log" ]
}

@test "the seat's push stops when the placed public differs" {
  printf '%s\ncat >/dev/null\necho "host-key ssh-ed25519 AAAAtampered"\n' "$shebang" >"$t/seat-receive"
  seat_push
  [ "$status" -eq 1 ]
  [[ $output == *"public differs from the one sent"* ]]
  [[ $output != *"next:"* ]]
}

@test "receive on the seat: a frame carrying an age identity writes nothing" {
  PATH="$t/bin:$PATH" run "$t/seat-receive" --accept < <(frame bioskop)
  [ "$status" -eq 1 ]
  [[ $output == *"an age identity, which bioskop does not take — refused, nothing written"* ]]
  [ -z "$(find "$t/seat-root" -type f)" ]
  [[ $output != *AGE-SECRET-KEY* ]]
}

@test "receive on a NixOS guest: a frame without the age identity writes nothing" {
  receive < <(printf 'ndh-identity/1 bioskop-nixos\n%s\nend\n' "$(<"$t/machine")")
  [ "$status" -eq 1 ]
  [[ $output == *"a malformed age identity — refused, nothing written"* ]]
  nothing_placed
}

@test "a push without the sshfs key, to a guest that mounts sshfs, writes nothing and does not reload" {
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash "$t/push" bioskop-nixos 3<"$t/machine" 4<"$t/seat" 5<&-
  [ "$status" -eq 1 ]
  [[ $output == *"no sshfs key, which bioskop-nixos takes"*"refused, nothing written"* ]]
  [ ! -e "$t/reloaded" ]
  nothing_placed
}

@test "the push refuses an fd 5 that is not an unencrypted ed25519 key, or is the host key, before sending" {
  ssh-keygen -q -t ed25519 -N secret -C locked -f "$t/locked"
  for bad in "$t/locked" /dev/null "$t/machine"; do
    TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash "$t/push" bioskop-nixos 3<"$t/machine" 4<"$t/seat" 5<"$bad"
    [ "$status" -eq 1 ]
    [[ $output == *"fd 5 "* ]]
  done
  [ ! -e "$t/ssh.log" ]
  nothing_placed
}

@test "the seat's push refuses an sshfs key on fd 5, and sends nothing" {
  for c in route ifconfig ssh-keyscan ssh; do
    printf '%s\necho %s >>%q\nexit 95\n' "$shebang" "$c" "$t/network.log" >"$t/bin/$c"
  done
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash "$t/push" bioskop 3<"$t/machine" 4<&- 5<"$t/sshfs"
  [ "$status" -eq 1 ]
  [[ $output == *"close fd 5"* ]]
  [ ! -e "$t/sudo.log" ]
  [ ! -e "$t/network.log" ]
}

@test "receive on a guest that does not mount sshfs: a frame carrying an sshfs key writes nothing" {
  PATH="$t/bin:$PATH" run "$t/no-sshfs-receive" --accept < <(frame bioskop-nixos)
  [ "$status" -eq 1 ]
  [[ $output == *"an sshfs key, which bioskop-nixos does not take — refused, nothing written"* ]]
  nothing_placed
  [[ $output != *"PRIVATE KEY"* ]]
}

@test "receive on a guest that does not mount sshfs: its two-item frame is placed, and no sshfs key" {
  PATH="$t/bin:$PATH" run "$t/no-sshfs-receive" --accept < <(frame bioskop-nixos "")
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$hostKeyFile")" = 400 ]
  [ ! -e "$sshfsKeyFile" ]
  [[ $output != *"sshfs-key"* ]]
}

@test "receive: a damaged sshfs key writes nothing, not even the other two" {
  receive < <(frame bioskop-nixos | awk -v n="$(($(wc -l <"$t/machine") + 4))" 'NR == n { $0 = "!" substr($0, 2) } { print }')
  [ "$status" -eq 1 ]
  [[ $output == *"a malformed sshfs key — refused, nothing written"* ]]
  nothing_placed
}

@test "receive: an sshfs key that does not load, or is the host key, writes nothing" {
  receive < <(frame bioskop-nixos | awk -v n="$(($(wc -l <"$t/machine") + 4))" 'NR == n { $0 = "AAAA" substr($0, 5) } { print }')
  [ "$status" -eq 1 ]
  [[ $output == *"the sshfs key does not load — refused, nothing written"* ]]
  nothing_placed
  receive < <(frame bioskop-nixos "$t/machine")
  [ "$status" -eq 1 ]
  [[ $output == *"the sshfs key is the host key — refused, nothing written"* ]]
  nothing_placed
  [ -z "$(find "$t/root" -name '.ndh-identity.*')" ]
}

@test "receive: anything after the sshfs key but the frame end writes nothing" {
  receive < <(frame bioskop-nixos | sed '$i extra')
  [ "$status" -eq 1 ]
  [[ $output == *"a malformed frame end — refused, nothing written"* ]]
  receive < <(frame bioskop-nixos | sed '$d')
  [ "$status" -eq 1 ]
  nothing_placed
}

# A receive whose keys.yaml records something else than the frame carries.
receive_recording() { # <host key pub> <sshfs pub> <access point pub>
  { printf 'set -euo pipefail\n'; recorded "$1" "$2" "$3"
    printf 'machine=bioskop-nixos keyFile=%q hostKeyFile=%q sshfsKeyFile=%q served=%q owner="" maxBytes=8192\n' \
      "$keyFile" "$hostKeyFile" "$sshfsKeyFile" "$t/served.pub"
    cat "$here/ndh-identity-receive.sh"; } >"$t/bin/ndh-identity-receive"
}

@test "receive: nothing recorded for the machine writes nothing" {
  receive_recording /dev/null "$t/sshfs.pub" "$t/seat.pub"
  receive < <(frame bioskop-nixos)
  [ "$status" -eq 1 ]
  [[ $output == *"keys.yaml records no host-bioskop-nixos"* ]]
  nothing_placed
}

@test "receive: a host key other than the recorded one writes nothing" {
  receive_recording "$t/served.pub" "$t/sshfs.pub" "$t/seat.pub"
  receive < <(frame bioskop-nixos)
  [ "$status" -eq 1 ]
  [[ $output == *"the host key is not host-bioskop-nixos's"* ]]
  nothing_placed
}

@test "receive: an sshfs key other than the recorded one writes nothing" {
  receive_recording "$t/machine.pub" "$t/operator.pub" "$t/seat.pub"
  receive < <(frame bioskop-nixos)
  [ "$status" -eq 1 ]
  [[ $output == *"the sshfs key is not sshfs-bioskop-nixos's"* ]]
  nothing_placed
}

@test "receive: an age identity not derived from the recorded access point writes nothing" {
  receive_recording "$t/machine.pub" "$t/sshfs.pub" "$t/operator.pub"
  receive < <(frame bioskop-nixos)
  [ "$status" -eq 1 ]
  [[ $output == *"the age identity is not the one of bioskop-nixos's access point"* ]]
  nothing_placed
}
