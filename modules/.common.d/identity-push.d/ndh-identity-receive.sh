# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
unset BASH_XTRACEFD 2>/dev/null || true

# ndh-identity-receive — the machine's side of ndh-identity-push (docs/ssh-keys-architecture.adoc).
#
# Without an argument, at the console: prints the fingerprint of the key this machine's sshd serves,
# the one the operator types into ndh-identity-push on bioskop before anything is sent.
#
# With --accept, run by the push through `sudo -n`: reads ONE identity frame on stdin, bounded, and
# places the age identity (the sops keyFile), the host key and, on a guest that mounts sshfs, its sshfs
# key: all or nothing. Each is written in a 0700 dir on the same filesystem, loaded, then renamed into
# place; any fault writes nothing. Only the publics are printed, for the push to compare with what it
# derived. Nothing here echoes the frame.
#
#   ndh-identity/1 <machine>
#   AGE-SECRET-KEY-1...                  (only when keyFile is set)
#   -----BEGIN OPENSSH PRIVATE KEY-----  the host key
#   ...
#   -----END OPENSSH PRIVATE KEY-----
#   -----BEGIN OPENSSH PRIVATE KEY-----  the sshfs key (only when sshfsKeyFile is set)
#   ...
#   -----END OPENSSH PRIVATE KEY-----
#   end
#
# The frame is exact by configuration: an item the machine takes is required, one it does not take is
# refused, never skipped.
#
# keyFile is empty on the operator seat: its sops keyFile still holds the retired identities that roles × keys
# S4/S8 replace once every file is re-keyed, so writing its access point's identity there now would break sops.
# Its frame is then the host key alone. sshfsKeyFile is set on a guest that mounts its operator seat's git
# stores (services.sshfsMounts), whose mounts use the key once the guest sets ndh.sshfs.ownKey.
#
# The host key is PLACED; sshd serves it once the machine sets ndh.hostKey.own (S3), and $served is then
# that private file, read as root.

log() { printf '[ndh-identity-receive] %s\n' "$*" >&2; }
die() {
  printf '[ndh-identity-receive] ERROR: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  "")
    [[ -r $served ]] || die "this machine's sshd serves no ed25519 key at ${served}"
    line="$(ssh-keygen -l -E sha256 -f "$served")" || die "${served} does not load"
    read -r _ fp _ <<<"$line"
    [[ ${line##* } == "(ED25519)" && $fp == SHA256:* ]] || die "${served} is not an ed25519 public key"
    printf 'machine      %s\nfingerprint  %s\n' "$machine" "$fp"
    exit 0
    ;;
  --accept) ;;
  *) die "usage: ndh-identity-receive [--accept]" ;;
esac

[[ -z $owner || $(id -u) -eq 0 ]] || die "--accept runs as root (the push calls it through sudo -n)"

frame="$(head -c "$((maxBytes + 1))")"
((${#frame} <= maxBytes)) || die "the frame exceeds ${maxBytes} bytes — refused, nothing written"
mapfile -t lines < <(printf '%s\n' "$frame")
unset frame
n=${#lines[@]}
refuse() { die "$1 — refused, nothing written"; }
begin="-----BEGIN OPENSSH PRIVATE KEY-----"
# One OpenSSH private key block starting at line $1: its BEGIN, base64 lines, its END. Sets `next` to the line after.
block() {
  local i=$1
  [[ ${lines[i]:-} == "$begin" ]] || return 1
  for ((i++; i < n; i++)); do
    if [[ ${lines[i]} == "-----END OPENSSH PRIVATE KEY-----" ]]; then
      ((i > $1 + 1)) || return 1
      next=$((i + 1))
      return 0
    fi
    [[ ${lines[i]} =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
  done
  return 1
}
h=1 # the host key's first line
[[ -z $keyFile ]] || h=2
((n >= h + 1)) || refuse "a malformed frame"
[[ ${lines[0]} == "ndh-identity/1 ${machine}" ]] || refuse "the frame is not addressed to ${machine}"
if [[ -n $keyFile ]]; then
  [[ ${lines[1]} =~ ^AGE-SECRET-KEY-1[0-9A-Z]{58}$ ]] || refuse "a malformed age identity"
else
  [[ ${lines[1]} != AGE-SECRET-KEY-* ]] || refuse "an age identity, which ${machine} does not take"
fi
block "$h" || refuse "a malformed host key"
sshfsAt=$next # the sshfs key's first line, or the frame end
if [[ -n $sshfsKeyFile ]]; then
  [[ ${lines[sshfsAt]:-} == "$begin" ]] || refuse "no sshfs key, which ${machine} takes (it mounts its operator seat's git stores)"
  block "$sshfsAt" || refuse "a malformed sshfs key"
else
  [[ ${lines[sshfsAt]:-} != "$begin" ]] || refuse "an sshfs key, which ${machine} does not take"
fi
((next == n - 1)) && [[ ${lines[next]} == end ]] || refuse "a malformed frame end"

hostKeyDir="$(dirname "$hostKeyFile")"
install -d -m 0700 "$hostKeyDir"
targets=("$hostKeyDir")
if [[ -n $sshfsKeyFile ]]; then
  install -d -m 0700 "$(dirname "$sshfsKeyFile")"
  targets+=("$(dirname "$sshfsKeyFile")")
fi
keyDir="$(dirname "${keyFile:-$hostKeyFile}")" # with no age identity, the stage sits beside the host key
mkdir -p "$keyDir"
stage="$(mktemp -d "$(dirname "$keyDir")/.ndh-identity.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
chmod 0700 "$stage"
# A rename is atomic only within one filesystem; across two it is a copy, which could leave half a file.
for d in "$keyDir" "${targets[@]}"; do
  [[ $(stat -c %d "$stage") == "$(stat -c %d "$d")" ]] || refuse "${d} is not on the filesystem of ${stage}"
done

(
  umask 077
  [[ -z $keyFile ]] || printf '%s\n' "${lines[1]}" >"$stage/age"
  printf '%s\n' "${lines[@]:h:sshfsAt-h}" >"$stage/host_key"
  [[ -z $sshfsKeyFile ]] || printf '%s\n' "${lines[@]:sshfsAt:n-1-sshfsAt}" >"$stage/sshfs_key"
)
unset lines
if [[ -n $keyFile ]]; then
  agePub="$(age-keygen -y "$stage/age" 2>/dev/null)" || refuse "the age identity does not load"
fi
read -r hostType hostBlob _ < <(ssh-keygen -y -f "$stage/host_key" 2>/dev/null) || refuse "the host key does not load"
[[ $hostType == ssh-ed25519 ]] || refuse "the host key is not ed25519"
if [[ -n $sshfsKeyFile ]]; then
  read -r sshfsType sshfsBlob _ < <(ssh-keygen -y -f "$stage/sshfs_key" 2>/dev/null) || refuse "the sshfs key does not load"
  [[ $sshfsType == ssh-ed25519 ]] || refuse "the sshfs key is not ed25519"
  # One key, one role: revoking either would cut the other.
  [[ $sshfsBlob != "$hostBlob" ]] || refuse "the sshfs key is the host key"
fi
# Only the keyring's keys: each item matches the public keys.yaml records for this machine, baked at build, so a
# local process that may run this receive cannot install a key of its own.
[[ -n $recordedHostKey ]] || refuse "keys.yaml records no host-${machine}: record it, then switch ${machine}, then push"
[[ "${hostType} ${hostBlob}" == "$recordedHostKey" ]] || refuse "the host key is not host-${machine}'s, as keys.yaml records it"
if [[ -n $sshfsKeyFile ]]; then
  [[ -n $recordedSshfsKey && "${sshfsType} ${sshfsBlob}" == "$recordedSshfsKey" ]] ||
    refuse "the sshfs key is not sshfs-${machine}'s, as keys.yaml records it"
fi
if [[ -n $keyFile ]]; then
  [[ -n $recordedAccessPoint && $agePub == "$(printf '%s\n' "$recordedAccessPoint" | ssh-to-age 2>/dev/null)" ]] ||
    refuse "the age identity is not the one of ${machine}'s access point, as keys.yaml records its host key"
fi

chmod 0400 "$stage"/*
[[ -z $owner ]] || chown "$owner" "$stage"/*
[[ -z $keyFile ]] || mv -f "$stage/age" "$keyFile"
[[ -z $sshfsKeyFile ]] || mv -f "$stage/sshfs_key" "$sshfsKeyFile"
mv -f "$stage/host_key" "$hostKeyFile"
log "placed ${keyFile:+$keyFile, }${sshfsKeyFile:+$sshfsKeyFile, }${hostKeyFile} (0400)"
[[ -z $keyFile ]] || printf 'age %s\n' "$agePub"
printf 'host-key %s %s\n' "$hostType" "$hostBlob"
[[ -z $sshfsKeyFile ]] || printf 'sshfs-key %s %s\n' "$sshfsType" "$sshfsBlob"
