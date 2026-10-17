# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
unset BASH_XTRACEFD 2>/dev/null || true

# ndh-keyring — the fleet's machine-held keys in the operator's keyring (docs/ssh-keys-architecture.adoc): the
# seedmatic/ part of their pass store, encrypted to the seedmatic subkey alone.
#
#   ndh-keyring host-key <machine>      a machine's ssh host key, as seedmatic/host-key/<machine>
#   ndh-keyring sshfs-key <guest>       the key a NixOS guest mounts its operator seat's git stores with,
#                                       as seedmatic/sshfs-key/<guest>
#   ndh-keyring vz-recover-key <host>   the key the sessions recover a foreign vz-host's VMs with, as
#                                       seedmatic/vz-recover-key/<host>, installed at ~/.ssh/vz-recover
#
# Generates the ed25519 key IN MEMORY and inserts it; the private only ever flows through pipes, never a
# variable, a file or an argument. Never overwrites: a replacement is a rotation, with its revocation.
# Before the insert, the entry's recipient must be the seedmatic subkey alone (pass encrypts to the
# NEAREST .gpg-id, and the store root's are personal keys); after it, the file's packets must name that
# subkey only, and the private read back must match the public. Prints publics only: recording the
# public in keys.yaml is the next step. The vz-recover key is also installed for this seat's ssh, whose
# vzrecover.nikopol Host block names the file so that no session does, and its authorized_keys line is
# printed on stderr for the operator to place in the vz-host account (never committed: it names that account).

log() { printf '[ndh-keyring] %s\n' "$*" >&2; }
die() {
  printf '[ndh-keyring] ERROR: %s\n' "$*" >&2
  exit 1
}
ulimit -c 0

usage="usage: ndh-keyring host-key <machine> | sshfs-key <guest> | vz-recover-key <host>"
[[ $# -eq 2 ]] || die "$usage"
kind="$1"
name="$2"
case "$kind" in
  host-key) allowed=("${machines[@]}") among="machines" recorded="host-${name}" usageTag=ssh-host ;;
  sshfs-key) allowed=("${guests[@]}") among="NixOS guests" recorded="sshfs-${name}" usageTag=ssh-user ;;
  vz-recover-key) allowed=("${vzHosts[@]}") among="foreign vz-hosts" recorded="vz-recover-${name}" usageTag=ssh-user ;;
  *) die "$usage" ;;
esac
known=0
for m in "${allowed[@]}"; do [[ $m == "$name" ]] && known=1; done
((known)) || die "${name} is not one of the inventory's ${among} (${allowed[*]})"
# Both bypass .gpg-id: the first replaces the recipients, the second can add one.
[[ -z ${PASSWORD_STORE_KEY:-} && -z ${PASSWORD_STORE_GPG_OPTS:-} ]] ||
  die "PASSWORD_STORE_KEY or PASSWORD_STORE_GPG_OPTS is set, which would override the seedmatic recipient — unset it"

store="${PASSWORD_STORE_DIR:-$HOME/.password-store}"
entry="seedmatic/${kind}/${name}"
[[ -f "$store/seedmatic/.gpg-id" && "$(<"$store/seedmatic/.gpg-id")" == "${recipient}!" ]] ||
  die "${store}/seedmatic/.gpg-id is not exactly ${recipient}! — refused, nothing generated"
[[ ! -e "$store/seedmatic/${kind}/.gpg-id" ]] ||
  die "${store}/seedmatic/${kind}/.gpg-id would override the seedmatic recipient — refused, nothing generated"
# The ONLY guard against an overwrite: `pass insert -m` fed by a pipe answers its own overwrite prompt yes.
[[ ! -e "$store/${entry}.gpg" ]] || die "${entry} exists; a key is never overwritten (a replacement is a rotation)"
installed="$HOME/.ssh/vz-recover"
[[ $kind != vz-recover-key || ! -e $installed ]] ||
  die "${installed} exists; a key is never overwritten (a replacement is a rotation) — nothing generated"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

"$generate" 3>"$work/generated.pub" | pass insert -m "$entry" >/dev/null ||
  die "generating or inserting ${entry} failed — an empty entry may exist: check with pass find ${kind}"
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

if [[ $kind == vz-recover-key ]]; then
  [[ -d $HOME/.ssh ]] || mkdir -m 0700 "$HOME/.ssh"
  if ! (umask 077 && pass show "$entry" >"${installed}.new") || ! mv "${installed}.new" "$installed"; then
    rm -f "${installed}.new"
    die "installing ${entry} at ${installed} failed — the entry is kept; nothing else was written"
  fi
  [[ "$(ssh-keygen -y -f "$installed" | awk '{ print $2 }')" == "$blob" ]] ||
    die "${installed} does not load as the generated key — check it, nothing was removed"
  log "${entry}: installed at ${installed} (0600)"
fi

fingerprint="$(ssh-keygen -l -E sha256 -f <(printf '%s %s\n' "$type" "$blob") | awk '{ print $2 }')"
printf '%s %s %s\n' "$type" "$blob" "$recorded"
log "${entry}: generated, encrypted to ${recipient} alone, read back; fingerprint ${fingerprint}"
log "next: record this public in keys.yaml: ... | ssh-keys-renew --create ${recorded} --public - --usage ${usageTag};"
log "replicate seedmatic/ with git subtree push — it carries seedmatic's history only while seedmatic/ is"
log "never deleted and re-created in the store"
if [[ $kind == vz-recover-key ]]; then
  log "then place this line in ~/.ssh/authorized_keys of ${name}'s vz-host account, by hand, and never commit it:"
  printf '%s %s %s %s\n' "${vzRecoverOptions[$name]}" "$type" "$blob" "$recorded" >&2
fi
