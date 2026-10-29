# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
export NDH_LOGGER_XTRACE=0 # ndh::logger:command:run traces its command unless this is 0
unset BASH_XTRACEFD 2>/dev/null || true
unset BASH_ENV # a caller's BASH_ENV holding `set -x` would trace every child bash this script starts

# ndh-keyring — the fleet's machine-held keys in the operator's keyring (docs/ssh-keys-architecture.adoc): the
# seedmatic/ part of their pass store, encrypted to the seedmatic subkey alone.
#
#   ndh-keyring host-key <machine>      a machine's ssh host key, as seedmatic/host-key/<machine>
#   ndh-keyring vz-recover-key <host>   the key the sessions recover a foreign vz-host's VMs with, as
#                                       seedmatic/vz-recover-key/<host>, installed at ~/.ssh/vz-recover
#   ndh-keyring nix-signing-public <machine>
#                                       prints the nix signing public derived from that machine's host key
#                                       (ndh-nix-signing-derive), for keys.yaml; generates and writes nothing
#   ndh-keyring cluster-age <n>         the cluster's age identity rke2lab-cluster-age-<n> (sops for the cluster:
#                                       Flux, the node bundle, the in-cluster render), as seedmatic/cluster-age/<n>;
#                                       prints its age public, for the .sops.yaml of rke2lab and nnh
#   ndh-keyring cluster-age-public <n>  prints that public again; generates and writes nothing
#   ndh-keyring age-key operator        the operator's own age identity, read on STDIN (the operator names its
#                                       file; this script never does), as seedmatic/age-key/operator: the one
#                                       identity whose public is .sops.yaml's operator recipient; keyhole's
#                                       online recipient (keyring@keyhole's), as seedmatic/age-key/keyhole@nxmatic; any
#                                       other identity in it is kept, as seedmatic/age-key/retired/<its public's
#                                       12 first characters>, never lost
#   ndh-keyring age-key-check operator  decrypts a sops file of this build by SOPS_AGE_KEY_CMD alone, with an
#                                       empty HOME, so no identity on disk can answer: then the file can go
#
# The cluster-age private leaves the keyring only on a file descriptor its consumer opens on `pass show`
# (the grow), never through this script.
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

usage="usage: ndh-keyring host-key <machine> | vz-recover-key <host> | nix-signing-public <machine>"
usage+=" | cluster-age <n> | cluster-age-public <n> | age-key operator | age-key-check operator"
[[ $# -eq 2 ]] || die "$usage"
kind="$1"
name="$2"
allowed=()
case "$kind" in
  host-key | nix-signing-public) allowed=("${machines[@]}") among="machines" recorded="${name}" usageTag=ssh-host ;;
  vz-recover-key) allowed=("${vzHosts[@]}") among="foreign vz-hosts" recorded="vz-recover-${name}" usageTag=ssh-user ;;
  # Not a machine: a version. A new <n> is a new key, so the version is the rotation.
  cluster-age | cluster-age-public)
    [[ $name =~ ^[1-9][0-9]*$ ]] || die "a cluster-age version is a positive integer, not ${name}"
    recorded="rke2lab-cluster-age-${name}"
    ;;
  age-key | age-key-check)
    [[ $name == operator ]] || die "the only age key the keyring holds is the operator's, not ${name}"
    recorded="$operatorRecipient"
    ;;
  *) die "$usage" ;;
esac
if ((${#allowed[@]})); then
  known=0
  for m in "${allowed[@]}"; do [[ $m == "$name" ]] && known=1; done
  ((known)) || die "${name} is not one of the inventory's ${among} (${allowed[*]})"
fi
# Both bypass .gpg-id: the first replaces the recipients, the second can add one.
[[ -z ${PASSWORD_STORE_KEY:-} && -z ${PASSWORD_STORE_GPG_OPTS:-} ]] ||
  die "PASSWORD_STORE_KEY or PASSWORD_STORE_GPG_OPTS is set, which would override the seedmatic recipient — unset it"

store="${PASSWORD_STORE_DIR:-$HOME/.password-store}"

# The machine's nix signing public, derived from the host key already in the keyring: nothing is generated or
# written, so nothing here needs the guards below. The private flows from pass to the deriver through a pipe.
if [[ $kind == nix-signing-public ]]; then
  hostEntry="seedmatic/host-key/${name}"
  [[ -f "$store/${hostEntry}.gpg" ]] || die "${hostEntry} is not in the keyring: its host key comes first"
  pass show "$hostEntry" |
    "$derive" --name "seedmatic-${name}-${nixSigningVersion}" --label "seedmatic/nix-signing/${nixSigningVersion}" --public ||
    die "deriving ${name}'s nix signing key from ${hostEntry} failed"
  log "next: record it in keys.yaml: ... | ssh-keys-renew --record-nix-signing ${recorded} --public -"
  exit 0
fi

# The cluster-age public, from the identity already in the keyring: nothing is generated or written, and the
# private flows from pass to age-keygen through a pipe.
if [[ $kind == cluster-age-public ]]; then
  ageEntry="seedmatic/cluster-age/${name}"
  [[ -f "$store/${ageEntry}.gpg" ]] || die "${ageEntry} is not in the keyring: generate it with ndh-keyring cluster-age ${name}"
  public="$(pass show "$ageEntry" | age-keygen -y 2>/dev/null)" || die "${ageEntry} does not read back as an age identity"
  [[ $public == age1* ]] || die "${ageEntry} does not read back as an age identity"
  printf '%s\n' "$public"
  exit 0
fi

# Writes nothing: sops answers only through SOPS_AGE_KEY_CMD, as this seat's shells and GUI apps call it.
if [[ $kind == age-key-check ]]; then
  [[ -n ${SOPS_AGE_KEY_CMD:-} ]] || die "SOPS_AGE_KEY_CMD is not set in this shell: open a new one after the switch"
  emptyHome="$(mktemp -d)"
  trap 'rm -rf "$emptyHome"' EXIT
  env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE HOME="$emptyHome" XDG_CONFIG_HOME="$emptyHome" \
    sops decrypt "$sopsProbe" >/dev/null 2>&1 ||
    die "sops cannot decrypt ${sopsProbe##*/} by SOPS_AGE_KEY_CMD alone: keep the identity file"
  log "sops decrypts by SOPS_AGE_KEY_CMD alone (${SOPS_AGE_KEY_CMD}): the identity file can be removed"
  exit 0
fi

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

# The packets, read without decrypting: exactly one recipient, the seedmatic subkey.
checkRecipient() {
  local keyids
  mapfile -t keyids < <(gpg --batch --list-only --list-packets "$store/${entry}.gpg" 2>/dev/null |
    sed -n 's/^:pubkey enc packet:.* keyid \([0-9A-Fa-f]*\).*/\1/p')
  [[ ${#keyids[@]} -eq 1 && ${keyids[0]^^} == "${recipient^^}" ]] ||
    die "${entry} is encrypted to [${keyids[*]}], not to ${recipient} alone — check it, nothing was removed"
}

# The cluster's age identity: age-keygen writes the identity on stdout, straight into pass, and its public on
# stderr when stdout is not a terminal.
if [[ $kind == cluster-age ]]; then
  # With pipefail the insert may have run before age-keygen failed: the way out is to remove that entry.
  age-keygen 2>"$work/generated.pub" | pass insert -m "$entry" >/dev/null ||
    die "generating or inserting ${entry} failed — an empty entry may exist: check with pass find ${kind}, then pass rm ${entry}"
  public="$(sed -n 's/^Public key: \(age1[0-9a-z]*\)$/\1/p' "$work/generated.pub")"
  [[ $public == age1* ]] || die "age-keygen returned no age public"
  checkRecipient
  [[ "$(pass show "$entry" | age-keygen -y 2>/dev/null)" == "$public" ]] ||
    die "${entry} reads back as another identity than the one generated — check it, nothing was removed"
  printf '%s\n' "$public"
  log "${entry}: generated, encrypted to ${recipient} alone, read back; it is ${recorded}"
  log "next: name this public in the .sops.yaml of rke2lab and nnh and re-key them (sops updatekeys);"
  log "the grow reads the private on fd 3, which YOUR shell opens on the grow's command line,"
  log "3< <(pass show ${entry}); never write that into a script"
  log "replicate seedmatic/ with git subtree push — it carries seedmatic's history only while seedmatic/ is"
  log "never deleted and re-created in the store"
  exit 0
fi

# The operator's identity, from stdin to pass: never a variable or a file here. Stdin goes whole into a pending
# entry; each identity is then taken from it BY ITS INDEX, through pipes, into its own entry: the operator's, and
# every other one under retired/, never lost. Every target is checked free before any is written, and the pending
# entry is removed however the run ends.
if [[ $kind == age-key ]]; then
  [[ ! -t 0 ]] || die "the identity is read on stdin: ndh-keyring age-key operator < <its file>"
  [[ ! -e "$store/seedmatic/age-key/retired/.gpg-id" ]] ||
    die "${store}/seedmatic/age-key/retired/.gpg-id would override the seedmatic recipient — refused, nothing written"
  operatorEntry="$entry"
  pending="seedmatic/age-key/import-pending"
  [[ ! -e "$store/${pending}.gpg" ]] || die "${pending} exists: a previous import did not finish — check it, then pass rm ${pending}"
  identityOf() { pass show "$pending" | grep '^AGE-SECRET-KEY-' | sed -n "${1}p"; } # <index>, on stdout, to a pipe
  trap 'pass rm -f "$pending" >/dev/null 2>&1; rm -rf "$work"' EXIT
  pass insert -m "$pending" >/dev/null || die "reading the identities into ${pending} failed"
  entry="$pending" && checkRecipient
  count="$(pass show "$pending" | grep -c '^AGE-SECRET-KEY-')" || count=0
  ((count > 0)) || die "stdin holds no age identity — nothing written"
  publics=()
  for ((n = 1; n <= count; n++)); do
    publics+=("$(identityOf "$n" | age-keygen -y 2>/dev/null)") || die "identity ${n} on stdin does not read as an age identity — nothing written"
  done
  operatorAt=0 targets=()
  for ((n = 1; n <= count; n++)); do
    p="${publics[n - 1]}"
    [[ $p == age1* ]] || die "identity ${n} on stdin does not read as an age identity — nothing written"
    if [[ $p == "$operatorRecipient" ]]; then
      ((operatorAt == 0)) || die "stdin holds the operator identity twice — nothing written"
      operatorAt=$n targets+=("$operatorEntry")
    elif [[ $p == "$keyringRecipient" ]]; then
      targets+=("seedmatic/age-key/keyhole@nxmatic")
    else
      targets+=("seedmatic/age-key/retired/${p:0:12}")
    fi
  done
  ((operatorAt > 0)) || die "stdin holds ${count} identity(ies), none of them ${operatorRecipient}: ${publics[*]} — nothing written"
  for target in "${targets[@]}"; do
    [[ ! -e "$store/${target}.gpg" ]] || die "${target} exists; a key is never overwritten — nothing written"
  done
  [[ $(printf '%s\n' "${targets[@]}" | sort -u | wc -l) -eq $count ]] || die "two identities share an entry name — nothing written"
  for ((n = 1; n <= count; n++)); do
    entry="${targets[n - 1]}"
    identityOf "$n" | pass insert -m "$entry" >/dev/null || die "inserting ${entry} failed — check with pass find age-key"
    checkRecipient
    [[ "$(pass show "$entry" | age-keygen -y 2>/dev/null)" == "${publics[n - 1]}" ]] ||
      die "${entry} reads back as another identity than ${publics[n - 1]} — check it"
    printf '%s %s\n' "${publics[n - 1]}" "$entry"
  done
  log "${operatorEntry}: inserted, encrypted to ${recipient} alone, read back as ${operatorRecipient}"
  ((count == 1)) || log "the $((count - 1)) other identity(ies): kept as named above (keyhole's as keyhole@nxmatic, the rest under retired/)"
  log "next, after the switch, in a NEW shell: ndh-keyring age-key-check operator"
  exit 0
fi

"$generate" 3>"$work/generated.pub" | pass insert -m "$entry" >/dev/null ||
  die "generating or inserting ${entry} failed — an empty entry may exist: check with pass find ${kind}"
read -r type blob _ <"$work/generated.pub"
[[ $type == ssh-ed25519 && -n $blob ]] || die "the generator returned no ed25519 public"

checkRecipient

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
