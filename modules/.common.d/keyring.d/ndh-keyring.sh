# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
unset BASH_XTRACEFD 2>/dev/null || true

# ndh-keyring — the machines' host keys in the operator's keyring (docs/ssh-keys-architecture.adoc): the
# seedmatic/ part of their pass store, encrypted to the seedmatic subkey alone.
#
#   ndh-keyring host-key <machine>
#
# Generates the machine's ed25519 host key IN MEMORY and inserts it as seedmatic/host-key/<machine>; the
# private only ever flows through pipes, never a variable, a file or an argument. Never overwrites: a
# replacement is a rotation, with its revocation. Before the insert, the entry's recipient must be the
# seedmatic subkey alone (pass encrypts to the NEAREST .gpg-id, and the store root's are personal keys);
# after it, the file's packets must name that subkey only, and the private read back must match the
# public. Prints publics only: recording the public in keys.yaml is the next step.

log() { printf '[ndh-keyring] %s\n' "$*" >&2; }
die() {
  printf '[ndh-keyring] ERROR: %s\n' "$*" >&2
  exit 1
}
ulimit -c 0

[[ $# -eq 2 && $1 == host-key ]] || die "usage: ndh-keyring host-key <machine>"
machine="$2"
[[ " ${machines[*]} " == *" ${machine} "* ]] || die "${machine} is not one of the inventory's machines (${machines[*]})"

store="${PASSWORD_STORE_DIR:-$HOME/.password-store}"
entry="seedmatic/host-key/${machine}"
[[ -f "$store/seedmatic/.gpg-id" && "$(<"$store/seedmatic/.gpg-id")" == "${recipient}!" ]] ||
  die "${store}/seedmatic/.gpg-id is not exactly ${recipient}! — refused, nothing generated"
[[ ! -e "$store/seedmatic/host-key/.gpg-id" ]] ||
  die "${store}/seedmatic/host-key/.gpg-id would override the seedmatic recipient — refused, nothing generated"
[[ ! -e "$store/${entry}.gpg" ]] || die "${entry} exists; a host key is never overwritten (a replacement is a rotation)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

"$generate" 3>"$work/generated.pub" | pass insert -m "$entry" >/dev/null || die "pass insert of ${entry} failed"
read -r type blob _ <"$work/generated.pub"
[[ $type == ssh-ed25519 && -n $blob ]] || die "the generator returned no ed25519 public"

# The packets, read without decrypting: exactly one recipient, the seedmatic subkey.
mapfile -t keyids < <(gpg --batch --list-only --list-packets "$store/${entry}.gpg" 2>/dev/null |
  sed -n 's/^:pubkey enc packet:.* keyid \([0-9A-Fa-f]*\).*/\1/p')
[[ ${#keyids[@]} -eq 1 && ${keyids[0]^^} == "${recipient^^}" ]] ||
  die "${entry} is encrypted to [${keyids[*]}], not to ${recipient} alone — check it, nothing was removed"

# The private read back loads, and is the generated key: its age conversion equals the public's.
fromPrivate="$(pass show "$entry" | ssh-to-age -private-key | age-keygen -y)" ||
  die "${entry} does not read back as an ed25519 private — check it, nothing was removed"
[[ $fromPrivate == "$(printf '%s %s\n' "$type" "$blob" | ssh-to-age)" ]] ||
  die "${entry} reads back as another key than the one generated — check it, nothing was removed"

fingerprint="$(ssh-keygen -l -E sha256 -f <(printf '%s %s\n' "$type" "$blob") | awk '{ print $2 }')"
printf '%s %s host-%s\n' "$type" "$blob" "$machine"
log "${entry}: generated, encrypted to ${recipient} alone, read back; fingerprint ${fingerprint}"
log "next: record this public in keys.yaml (host-${machine}); replicate seedmatic/ with git subtree push —"
log "it carries seedmatic's history only while seedmatic/ is never deleted and re-created in the store"
