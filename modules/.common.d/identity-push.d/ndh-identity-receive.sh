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
# places the age identity (the sops keyFile) and the host key, both or nothing. Both are written in a
# 0700 dir on the same filesystem, loaded, then renamed into place; any fault writes nothing. Only the
# publics are printed, for the push to compare with what it derived. Nothing here echoes the frame.
#
#   ndh-identity/1 <machine>
#   AGE-SECRET-KEY-1...
#   -----BEGIN OPENSSH PRIVATE KEY-----
#   ...
#   -----END OPENSSH PRIVATE KEY-----
#   end
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
((n >= 6)) || refuse "a malformed frame"
[[ ${lines[0]} == "ndh-identity/1 ${machine}" ]] || refuse "the frame is not addressed to ${machine}"
[[ ${lines[1]} =~ ^AGE-SECRET-KEY-1[0-9A-Z]{58}$ ]] || refuse "a malformed age identity"
[[ ${lines[2]} == "-----BEGIN OPENSSH PRIVATE KEY-----" ]] || refuse "a malformed host key"
[[ ${lines[n - 2]} == "-----END OPENSSH PRIVATE KEY-----" && ${lines[n - 1]} == end ]] || refuse "a malformed frame end"
for ((i = 3; i < n - 2; i++)); do
  [[ ${lines[i]} =~ ^[A-Za-z0-9+/=]+$ ]] || refuse "a malformed host key"
done

keyDir="$(dirname "$keyFile")"
hostKeyDir="$(dirname "$hostKeyFile")"
mkdir -p "$keyDir"
install -d -m 0700 "$hostKeyDir"
stage="$(mktemp -d "$(dirname "$keyDir")/.ndh-identity.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
chmod 0700 "$stage"
# A rename is atomic only within one filesystem; across two it is a copy, which could leave half a file.
for d in "$keyDir" "$hostKeyDir"; do
  [[ $(stat -c %d "$stage") == "$(stat -c %d "$d")" ]] || refuse "${d} is not on the filesystem of ${stage}"
done

(
  umask 077
  printf '%s\n' "${lines[1]}" >"$stage/age"
  printf '%s\n' "${lines[@]:2:n-3}" >"$stage/host_key"
)
unset lines
agePub="$(age-keygen -y "$stage/age" 2>/dev/null)" || refuse "the age identity does not load"
read -r hostType hostBlob _ < <(ssh-keygen -y -f "$stage/host_key" 2>/dev/null) || refuse "the host key does not load"
[[ $hostType == ssh-ed25519 ]] || refuse "the host key is not ed25519"

chmod 0400 "$stage/age" "$stage/host_key"
[[ -z $owner ]] || chown "$owner" "$stage/age" "$stage/host_key"
mv -f "$stage/age" "$keyFile"
mv -f "$stage/host_key" "$hostKeyFile"
log "placed ${keyFile} and ${hostKeyFile} (0400)"
printf 'age %s\nhost-key %s %s\n' "$agePub" "$hostType" "$hostBlob"
