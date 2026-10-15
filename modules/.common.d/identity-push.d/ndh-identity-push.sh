# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
unset BASH_XTRACEFD 2>/dev/null || true

# ndh-identity-push — bioskop gives a machine its identities (docs/ssh-keys-architecture.adoc): its
# SSH host key and the age identity of its access point, ssh-to-age of the SEAT's host key. A gesture
# of the operator, with the keyring open; the machine asks for nothing.
#
#   ndh-identity-push <machine> 3<"the machine's host key" 4<"the seat's host key"
#
# The privates come on file descriptors fed by the keyring, so its format stays its own, and they are
# never written on this side: the age identity is derived in memory, the host key's public is read from
# the key's own encoding (ssh-keygen refuses a pipe).
#
# ★ The target is authenticated by the fingerprint its sshd serves, read by the operator at its
# console (`ndh-identity-receive`) and typed here: ssh then trusts THAT key only. This stands on the
# operator's assumption that the home LAN carries only their devices (they grant access to its
# hotspot and start the VMs): the guest is L2-bridged onto that LAN, so the bridge itself proves nothing.
# The address is the inventory's, never a DNS answer, and must be reached through this seat's own link.

log() { printf '[ndh-identity-push] %s\n' "$*" >&2; }
die() {
  printf '[ndh-identity-push] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || die "usage: ndh-identity-push <machine> 3<the machine's host key 4<the seat's host key"
[[ $1 == "$machine" ]] || die "${seat} pushes to ${machine} only, not to $1"
{ : <&3; } 2>/dev/null || die "file descriptor 3 (the machine's host key) is not open"
{ : <&4; } 2>/dev/null || die "file descriptor 4 (the seat's host key) is not open"
machineKey="$(head -c "$((maxBytes + 1))" <&3)"
seatKey="$(head -c "$((maxBytes + 1))" <&4)"
exec 3<&- 4<&-

# "ssh-ed25519 <blob>" of an UNENCRYPTED ed25519 OpenSSH private key, read from its encoding: the
# fixed header (magic, cipher none, kdf none, no kdf options, one key, a 51-byte public) then the public.
hostPubOf() {
  local body
  [[ ${#1} -le $maxBytes && $1 == "-----BEGIN OPENSSH PRIVATE KEY-----"$'\n'*$'\n'"-----END OPENSSH PRIVATE KEY-----" ]] || return 1
  body="$(printf '%s\n' "$1" | sed '1d;$d' | tr -d '\n')"
  [[ "$(printf '%s' "$body" | base64 -d 2>/dev/null | head -c 43 | base64 | tr -d '\n')" == \
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMw== ]] || return 1
  printf 'ssh-ed25519 %s\n' "$(printf '%s' "$body" | base64 -d | tail -c +44 | head -c 51 | base64 | tr -d '\n')"
}
machinePub="$(hostPubOf "$machineKey")" || die "fd 3 is not an unencrypted ed25519 OpenSSH private key"
hostPubOf "$seatKey" >/dev/null || die "fd 4 is not an unencrypted ed25519 OpenSSH private key"
ageKey="$(printf '%s\n' "$seatKey" | ssh-to-age -private-key 2>/dev/null)" || die "fd 4 does not convert to an age identity"
unset seatKey
agePub="$(printf '%s\n' "$ageKey" | age-keygen -y 2>/dev/null)" || die "the derived age identity does not load"
log "${machine}: host key ${machinePub#ssh-ed25519 }"
log "${machine}: age identity of the ${seat} access point ${agePub}"

# This seat's own link to the machine: the route to its address leaves by the interface holding ours.
iface="$(route -n get "$address" 2>/dev/null | awk '/interface:/ { print $2 }')"
if [[ -z $iface ]] || ! ifconfig "$iface" 2>/dev/null | grep -F "inet ${localAddress} " >/dev/null; then
  die "${address} is not reached through ${seat}'s own link (${localAddress}) — refused, nothing sent"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

printf 'The fingerprint %s printed by ndh-identity-receive at its console: ' "$machine" >&2
read -r typed <"$ttyIn" || die "no fingerprint typed"
typed="${typed//[[:space:]]/}"
[[ $typed =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || die "not a SHA256 fingerprint (SHA256: and 43 characters)"
mapfile -t scanned < <(ssh-keyscan -T 10 -t ed25519 "$address" 2>/dev/null | grep -v '^#')
((${#scanned[@]} == 1)) || die "${address} serves no single ed25519 key"
read -r _ served _ < <(ssh-keygen -l -E sha256 -f <(printf '%s\n' "${scanned[0]}"))
[[ $served == "$typed" ]] || die "${address} serves ${served}, not the ${typed} read at the console — refused, nothing sent"
printf '%s\n' "${scanned[0]}" >"$work/known_hosts"

# ONE identity, no agent, no forwarding, no multiplexing, and ONLY the key just confirmed is trusted.
sshq() {
  ssh -o IdentityAgent=none -o IdentitiesOnly=yes -o IdentityFile="$sshKey" -o CertificateFile="$sshCert" \
    -o User="$sshUser" -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none \
    -o UserKnownHostsFile="$work/known_hosts" -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes \
    -o HostKeyAlgorithms=ssh-ed25519 -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
    "$address" "$@"
}
# On a NixOS machine the SETUID sudo is the wrapper; a non-interactive PATH finds the plain copy first.
rsudo=/run/wrappers/bin/sudo

placed="$(printf 'ndh-identity/1 %s\n%s\n%s\nend\n' "$machine" "$ageKey" "$machineKey" |
  sshq "$rsudo -n ndh-identity-receive --accept")" || die "${machine} refused the identities (its message is above)"
unset ageKey machineKey
[[ $placed == "age ${agePub}"$'\n'"host-key ${machinePub}" ]] ||
  die "${machine} placed identities whose publics differ from the ones sent — NOT reloaded; check it at its console"
log "${machine}: both placed and checked by their publics"

sshq "$rsudo -n ndh-identity-reload" >&2 || die "placed, but ndh-identity-reload failed on ${machine}: run it at its console"
log "${machine}: sops and its readers restarted"
