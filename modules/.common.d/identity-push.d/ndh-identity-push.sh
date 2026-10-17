# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
unset BASH_XTRACEFD 2>/dev/null || true

# ndh-identity-push — bioskop gives a machine its identities (docs/ssh-keys-architecture.adoc): its
# SSH host key, the age identity of its access point, ssh-to-age of the operator seat's host key, and for a
# NixOS guest that mounts its operator seat's git stores, its sshfs key. A gesture of the operator, with the
# keyring open; the machine asks for nothing.
#
#   ndh-identity-push <guest> 3<"the guest's host key" 4<"its access point's host key" [5<"its sshfs key"]
#   ndh-identity-push <darwin host> 3<"its host key"
#   ndh-identity-push <seat> 3<"the operator seat's host key"
#
# The seat holding the keyring pushes to any machine of the inventory whose address it reaches on its own link: its
# guest over their /30, the other metalspace's machines over the home LAN while that bare-metal is home (roles ×
# keys ④, 🛡️'s option C). The targets are baked from the inventory; a darwin host takes its host key only, as the
# seat itself does, through its receive by its fixed path under sudo -n (a sudoers rule names that command alone).
#
# fd 5 is optional here because the machine's receive decides: it requires the sshfs key when it mounts
# sshfs and refuses it otherwise, so the frame stays exact by the machine's configuration.
#
# The privates come on file descriptors fed by the keyring, so its format stays its own, and they are
# never written on this side: the age identity is derived in memory, the host key's public is read from
# the key's own encoding (ssh-keygen refuses a pipe).
#
# ★ The target is authenticated by the fingerprint its sshd serves, read by the operator at its
# console (`ndh-identity-receive`) and typed here: ssh then trusts THAT key only. This stands on the
# operator's assumption that the home LAN carries only their devices (they grant access to its
# hotspot and start the VMs): the guest is L2-bridged onto that LAN, so the bridge itself proves nothing.
# The address is the inventory's, never a DNS answer, and must be reached through this operator seat's own link.
#
# The operator seat itself takes its host key ONLY (ndh-identity-receive says why), through its local receive:
# nothing crosses a network, so there is no fingerprint to confirm and no ssh.

log() { printf '[ndh-identity-push] %s\n' "$*" >&2; }
die() {
  printf '[ndh-identity-push] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || die "usage: ndh-identity-push <guest> 3<its host key 4<its access point's host key [5<its sshfs key] | <darwin host> 3<its host key | <seat> 3<its host key"
target=$1
if [[ $target != "$seat" ]]; then
  [[ -v "targetKind[$target]" ]] || die "${seat} pushes to the inventory's machines (${!targetKind[*]}) or to itself, not to ${target}"
  machine=$target kind=${targetKind[$target]} address=${targetAddress[$target]} localAddress=${targetLocal[$target]}
fi
{ : <&3; } 2>/dev/null || die "file descriptor 3 (${target}'s host key) is not open"
sshfsGiven=0
if [[ $target == "$seat" || $kind == darwin ]]; then
  # A key given for an identity the seat does not take would be dropped unseen: refused instead.
  if { : <&4; } 2>/dev/null; then
    die "${target} takes its host key only, on fd 3: close fd 4 (its age identity is not placed yet)"
  fi
  if { : <&5; } 2>/dev/null; then
    die "${target} takes its host key only, on fd 3: close fd 5 (an sshfs key is a NixOS guest's)"
  fi
else
  { : <&4; } 2>/dev/null || die "file descriptor 4 (${target}'s access point's host key) is not open"
  seatKey="$(head -c "$((maxBytes + 1))" <&4)"
  if { : <&5; } 2>/dev/null; then
    sshfsGiven=1
    sshfsKey="$(head -c "$((maxBytes + 1))" <&5)"
  fi
fi
machineKey="$(head -c "$((maxBytes + 1))" <&3)"
exec 3<&- 4<&- 5<&-

# "ssh-ed25519 <blob>" of an UNENCRYPTED ed25519 OpenSSH private key, read from its encoding: the
# fixed header (magic, cipher none, kdf none, no kdf options, one key, a 51-byte public) then the public.
pubOf() {
  local body
  [[ ${#1} -le $maxBytes && $1 == "-----BEGIN OPENSSH PRIVATE KEY-----"$'\n'*$'\n'"-----END OPENSSH PRIVATE KEY-----" ]] || return 1
  body="$(printf '%s\n' "$1" | sed '1d;$d' | tr -d '\n')"
  [[ "$(printf '%s' "$body" | base64 -d 2>/dev/null | head -c 43 | base64 | tr -d '\n')" == \
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMw== ]] || return 1
  printf 'ssh-ed25519 %s\n' "$(printf '%s' "$body" | base64 -d | tail -c +44 | head -c 51 | base64 | tr -d '\n')"
}
machinePub="$(pubOf "$machineKey")" || die "fd 3 is not an unencrypted ed25519 OpenSSH private key"

if [[ $target == "$seat" ]]; then
  log "${seat}: host key ${machinePub#ssh-ed25519 }"
  placed="$(printf 'ndh-identity/1 %s\n%s\nend\n' "$seat" "$machineKey" | "$localSudo" -n "$localReceive" --accept)" ||
    die "${seat} refused its host key (its message is above; sudo -n needs credentials cached by sudo -v)"
  unset machineKey
  [[ $placed == "host-key ${machinePub}" ]] ||
    die "${seat} placed a host key whose public differs from the one sent — check it before serving it"
  log "${seat}: host key placed and checked by its public"
  log "next: commit ndh.hostKey.own = true for ${seat}, then switch; then on BOTH operator seats, for each name of ${seat}:"
  log "  ssh-keygen -R <name>, then ssh -o HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com <name> true"
  exit 0
fi

ageLine=""
expected="host-key ${machinePub}"
log "${machine}: host key ${machinePub#ssh-ed25519 }"
if [[ $kind == nixos ]]; then
  pubOf "$seatKey" >/dev/null || die "fd 4 is not an unencrypted ed25519 OpenSSH private key"
  ageKey="$(printf '%s\n' "$seatKey" | ssh-to-age -private-key 2>/dev/null)" || die "fd 4 does not convert to an age identity"
  unset seatKey
  agePub="$(printf '%s\n' "$ageKey" | age-keygen -y 2>/dev/null)" || die "the derived age identity does not load"
  ageLine="${ageKey}"$'\n'
  expected="age ${agePub}"$'\n'"${expected}"
  log "${machine}: age identity of its access point ${agePub}"
fi
sshfsItem=""
if ((sshfsGiven)); then
  sshfsPub="$(pubOf "$sshfsKey")" || die "fd 5 is not an unencrypted ed25519 OpenSSH private key"
  [[ $sshfsPub != "$machinePub" ]] || die "fd 5 holds the host key given on fd 3: the sshfs key is its own"
  sshfsItem="${sshfsKey}"$'\n'
  expected+=$'\n'"sshfs-key ${sshfsPub}"
  log "${machine}: sshfs key ${sshfsPub#ssh-ed25519 }"
fi
unset sshfsKey

# This operator seat's own link to the machine: the route to its address leaves by the interface holding ours.
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
# -F /dev/null: the options here are the whole configuration, so no `Host *` of the operator's can add a
# ProxyJump (away from the link checked above) or a LocalCommand. No password: a fallback fails, never prompts.
sshq() {
  ssh -F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
    -o IdentityAgent=none -o IdentitiesOnly=yes -o IdentityFile="$sshKey" -o CertificateFile="$sshCert" \
    -o User="$sshUser" -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none \
    -o UserKnownHostsFile="$work/known_hosts" -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes \
    -o HostKeyAlgorithms=ssh-ed25519 -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
    "$address" "$@"
}
# On a NixOS machine the SETUID sudo is the wrapper, which a non-interactive PATH does not find first; on a darwin
# host, macOS's own. The receive by its fixed path: the darwin sudoers rule names exactly that command.
case $kind in
  nixos) rsudo=/run/wrappers/bin/sudo ;;
  darwin) rsudo=/usr/bin/sudo ;;
esac
rbin=/run/current-system/sw/bin

placed="$(printf 'ndh-identity/1 %s\n%s%s\n%send\n' "$machine" "$ageLine" "$machineKey" "$sshfsItem" |
  sshq "$rsudo -n $rbin/ndh-identity-receive --accept")" || die "${machine} refused the identities (its message is above)"
unset ageKey ageLine machineKey sshfsItem
[[ $placed == "$expected" ]] ||
  die "${machine} placed identities whose publics differ from the ones sent — NOT reloaded; check it at its console"
log "${machine}: every identity placed and checked by its public"

if [[ $kind == darwin ]]; then
  log "next: commit ndh.hostKey.own = true for ${machine}, then switch it, locally"
  exit 0
fi
sshq "$rsudo -n $rbin/ndh-identity-reload" >&2 || die "placed, but ndh-identity-reload failed on ${machine}: run it at its console"
log "${machine}: sops and its readers restarted"
((sshfsGiven == 0)) || log "next: commit ndh.sshfs.ownKey = true for ${machine}, then switch it"
