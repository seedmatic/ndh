#!/usr/bin/env bats
#
# ndh-identity-push and ndh-identity-receive on their REAL path, the keys generated here. Only the outside
# world is stubbed, first on PATH: route and ifconfig (the seat's link), ssh-keyscan (what the machine's
# sshd serves) and ssh, which checks the pinning options and runs the real receive against a temp root.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/bin" "$t/tmp" "$t/root/var/lib/sops-nix"
  here="${BATS_TEST_DIRNAME}/.."
  key() { ssh-keygen -q -t ed25519 -N "${2:-}" -C "$1" -f "$t/$1"; }
  key machine
  key seat
  key served
  key operator

  keyFile="$t/root/var/lib/sops-nix/bioskop-nixos.age"
  hostKeyFile="$t/root/var/lib/ndh/host-key/ssh_host_ed25519_key"
  {
    printf 'set -euo pipefail\n'
    printf 'machine=bioskop-nixos keyFile=%q hostKeyFile=%q served=%q owner="" maxBytes=8192\n' \
      "$keyFile" "$hostKeyFile" "$t/served.pub"
    cat "$here/ndh-identity-receive.sh"
  } >"$t/bin/ndh-identity-receive"
  chmod +x "$t/bin/ndh-identity-receive"
  {
    printf 'set -euo pipefail\n'
    printf 'seat=bioskop machine=bioskop-nixos address=172.16.8.1 localAddress=172.16.8.2 maxBytes=8192\n'
    printf 'sshUser=nxmatic sshKey=%q sshCert=%q ttyIn=%q\n' "$t/operator" "$t/operator-cert.pub" "$t/typed"
    cat "$here/ndh-identity-push.sh"
  } >"$t/push"
  ssh-keygen -l -E sha256 -f "$t/served.pub" | awk '{ print $2 }' >"$t/typed"

  cat >"$t/bin/route" <<'EOF'
#!/usr/bin/env bash
printf '   route to: %s\n  interface: en9\n' "${@: -1}"
EOF
  cat >"$t/bin/ifconfig" <<'EOF'
#!/usr/bin/env bash
printf 'en9: flags=8963<UP>\n\tinet %s netmask 0xfffffffc\n' "${STUB_LOCAL:-172.16.8.2}"
EOF
  cat >"$t/bin/ssh-keyscan" <<EOF
#!/usr/bin/env bash
printf '# 172.16.8.1:22 SSH-2.0-OpenSSH\n172.16.8.1 %s\n' "\$(cut -d' ' -f1,2 "${STUB_SERVED:-$t/served.pub}")"
EOF
  cat >"$t/bin/ssh" <<EOF
#!/usr/bin/env bash
# The pinning is checked, not trusted: ONLY the throwaway known_hosts, holding the served key.
args=" \$* "
for o in "-F /dev/null " UserKnownHostsFile= "GlobalKnownHostsFile=/dev/null " "StrictHostKeyChecking=yes " \
  "IdentityAgent=none " "BatchMode=yes " "PasswordAuthentication=no " "KbdInteractiveAuthentication=no "; do
  [[ \$args == *"\$o"* ]] || { echo "ssh stub: missing -o \$o" >&2; exit 97; }
done
kh="\${args#* UserKnownHostsFile=}"; kh="\${kh%% *}"
grep -qF "\$(cut -d' ' -f2 "$t/served.pub")" "\$kh" || { echo "ssh stub: host key not pinned" >&2; exit 98; }
echo "\$*" >>"$t/ssh.log"
case "\${@: -1}" in
  *"ndh-identity-receive --accept")
    if [[ -n \${STUB_TAMPER:-} ]]; then ndh-identity-receive --accept | sed 's/^age .*/age age1tampered/'; else exec ndh-identity-receive --accept; fi ;;
  *"ndh-identity-reload") touch "$t/reloaded"; echo "[ndh-identity-reload] restarted" ;;
  *) echo "ssh stub: unexpected \${@: -1}" >&2; exit 99 ;;
esac
EOF
  chmod +x "$t/bin/"*
}

push() { TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash "$t/push" "$@" 3<"$t/machine" 4<"$t/seat"; }
nothing_placed() { [ ! -e "$keyFile" ] && [ ! -e "$hostKeyFile" ]; }
no_private_in() { ! grep -rqE 'AGE-SECRET-KEY|PRIVATE KEY' "$@"; }

@test "a push places both identities, 0400, checked by their publics, then reloads" {
  push bioskop-nixos
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$keyFile")" = 400 ]
  [ "$(stat -c %a "$hostKeyFile")" = 400 ]
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

@test "a seat pushes to its own guest only" {
  push nikopol-nixos
  [ "$status" -eq 1 ]
  [[ $output == *"pushes to bioskop-nixos only"* ]]
}

@test "a passphrase-protected key on fd 4 is refused before anything is sent" {
  ssh-keygen -q -t ed25519 -N secret -C seat2 -f "$t/seat2"
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash "$t/push" bioskop-nixos 3<"$t/machine" 4<"$t/seat2"
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

frame() { # <machine> — a valid frame for MACHINE
  printf 'ndh-identity/1 %s\n%s\n%s\nend\n' "$1" "$(ssh-to-age -private-key -i "$t/seat")" "$(<"$t/machine")"
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
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash -x "$t/push" bioskop-nixos 3<"$t/machine" 4<"$t/seat"
  [ "$status" -eq 0 ]
  [[ $output == *"[xtrace-guard] xtrace disabled"* ]]
  [[ $output != *AGE-SECRET-KEY* && $output != *"PRIVATE KEY"* ]]
}
