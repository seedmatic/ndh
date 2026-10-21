#!/usr/bin/env -S bash -euo pipefail
# @codebase
# ndh-host-key-generate: give this machine its next host key, born here (roles × keys K3, the fabric-delivery frame).
# Rendered by pkgs.replaceVars with the values of keys.yaml's ONE pending host-<machine> slot, shell-quoted: machine,
# slot, base (the root of the directory walk), slotDir, owner (0: root), keyFile, publishDir, oldKey, oldPublic. A
# machine with no pending slot does not build this at all.
#
# Idempotent at every activation: the private is generated once, by a rename into place, so it is absent or whole,
# never regenerated while present. The publication — the public and the F1 statement binding it to the machine's
# OLD certified key (namespace seedmatic-rotate) — is re-derived from that private every time, so a run that
# stopped between the two is completed by the next. Nothing serves the new key: sshd and sops keep the old one
# until keys.yaml records the slot and a later switch serves it.
#
# The run is traced into the system log (ndh's trampoline and logger), xtrace on, except around the lines that read
# or write a private: there xtrace is off. Only names, paths, fingerprints and publics are ever printed.
source @nixBashTrampoline@

readonly machine=@machine@ slot=@slot@ base=@base@ slotDir=@slotDir@ owner=@owner@
readonly keyFile=@keyFile@ publishDir=@publishDir@ oldKey=@oldKey@ oldPublic=@oldPublic@

die() {
  { set +x; } 2>/dev/null
  printf '[ndh-host-key-generate] ERROR: %s\n' "$*" >&2
  exit 1
}

# Around a line that handles a private: xtrace off, then back to what it was.
quiet() {
  local was=0 rc=0
  [[ $- == *x* ]] && was=1
  { set +x; } 2>/dev/null
  "$@" || rc=$?
  if ((was)); then set -x; fi
  return "$rc"
}

# owned_dirs <dir>…: from $base, every component down to each <dir> is a real directory owned by $owner, not a symlink
# and not group- or world-writable; what is missing is created one component at a time (0700 from the slot
# directory down, where the privates are; 0755 otherwise), so no `install -d` ever follows a link planted there.
owned_dirs() {
  local dir p c mode
  local -a rel
  for dir in "$@"; do
    [[ $dir == "$base"/* ]] || die "${dir} is not under ${base}"
    p="$base"
    IFS=/ read -ra rel <<<"${dir#"$base"/}"
    for c in "" "${rel[@]}"; do
      p="$p${c:+/$c}"
      if [[ ! -e $p && ! -L $p ]]; then
        mode=0755
        [[ $p == "$slotDir" || $p == "$slotDir"/* ]] && mode=0700
        install -d -m "$mode" "$p" || die "creating ${p} failed"
      fi
      [[ -d $p && ! -L $p ]] || die "${p} is not a directory (a symlink?): nothing written"
      [[ "$(stat -c %u "$p" 2>/dev/null || stat -f %u "$p")" == "$owner" ]] || die "${p} is not owned by uid ${owner}: nothing written"
      mode="$(stat -c %a "$p" 2>/dev/null || stat -f %Lp "$p")"
      (((8#$mode & 8#022) == 0)) || die "${p} is group- or world-writable (${mode}): nothing written"
    done
  done
}

born() { # the private, into a 0700 temp dir beside its place, then renamed: absent or whole
  local tmp
  tmp="$(mktemp -d "$(dirname "$keyFile")/.generate.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  ssh-keygen -q -t ed25519 -N "" -C "host-${machine}@${slot}" -f "$tmp/key" </dev/null || die "ssh-keygen failed"
  chmod 0600 "$tmp/key"
  mv -f "$tmp/key" "$keyFile"
  rm -rf "$tmp"
  trap - EXIT
}

public_of() { ssh-keygen -y -f "$1" | cut -d' ' -f1,2; }

main() {
  umask 077
  : "host-${machine}@${slot}: the key is born here; the one sshd serves stays until keys.yaml records this slot"
  owned_dirs "$(dirname "$keyFile")" "$publishDir"

  if [[ ! -e $keyFile && ! -L $keyFile ]]; then
    : "generating host-${machine}@${slot}, xtrace off while the private is written"
    quiet born
    printf '[ndh-host-key-generate] host-%s@%s generated at %s\n' "$machine" "$slot" "$keyFile" >&2
  fi
  [[ -f $keyFile && ! -L $keyFile ]] || die "${keyFile} is not a regular file"

  public="$(quiet public_of "$keyFile")" || die "${keyFile} is not a readable ed25519 private"
  [[ $public == ssh-ed25519\ * ]] || die "${keyFile} is not an ed25519 key"

  : "F1: the key sshd serves, the one keys.yaml records, vouches for the new public"
  [[ -s $oldKey ]] || die "no old host key at ${oldKey} to sign the new public with"
  [[ "$(quiet public_of "$oldKey")" == "$oldPublic" ]] ||
    die "${oldKey} is not the host key keys.yaml records for ${machine}: nothing published"

  work="$(mktemp -d "${publishDir}/.publish.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  printf 'seedmatic-rotate v1\nname host-%s\nslot %s\nkey %s\n' "$machine" "$slot" "$public" >"$work/statement"
  quiet ssh-keygen -q -Y sign -f "$oldKey" -n seedmatic-rotate "$work/statement" </dev/null || die "signing the statement failed"
  printf '%s\n' "$public" >"$work/public"
  chmod 0644 "$work/public" "$work/statement" "$work/statement.sig"
  for f in public statement statement.sig; do mv -f "$work/$f" "${publishDir}/host-${machine}@${slot}.${f}"; done
  rm -rf "$work"
  trap - EXIT
  printf '[ndh-host-key-generate] host-%s@%s published: %s\n' "$machine" "$slot" "$(ssh-keygen -lf "${publishDir}/host-${machine}@${slot}.public" | cut -d' ' -f2)" >&2
}

ndh::logger:command:run host-key.generate main "$@"
