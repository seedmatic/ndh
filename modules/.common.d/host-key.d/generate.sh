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
# The run logs into the system log through ndh's trampoline and logger, traced like any other: the private only ever
# moves between files and ssh-keygen, never through a variable, so a trace prints names, paths, fingerprints and
# publics alone.
source @nixBashTrampoline@

readonly machine=@machine@ slot=@slot@ base=@base@ slotDir=@slotDir@ owner=@owner@
readonly keyFile=@keyFile@ publishDir=@publishDir@ oldKey=@oldKey@ oldPublic=@oldPublic@
readonly keyRoot="${publishDir%/*}"
# `console` when the machine serves no key of its own to vouch for the new one (§o): the public goes out alone, and its
# fingerprint to the console, for the operator to compare with what `ops next` shows. Empty otherwise.
readonly bootstrap=@bootstrap@ console=@console@

die() {
  printf '[ndh-host-key-generate] ERROR: %s\n' "$*" >&2
  exit 1
}

# owned_dirs <dir>…: from $base, every component down to each <dir> is a real directory owned by $owner, not a symlink
# and not group- or world-writable; what is missing is created one component at a time (0700 from the slot
# directory down, where the privates are; 0755 otherwise), so no `install -d` ever follows a link planted there.
# The key root, publishDir's parent, is 0711 whether created or found (a pre-K5 machine made it 0700): the seat
# collects a publication over ssh as the operator's user, and traversing it lists none of the privates below.
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
        [[ $p == "$keyRoot" ]] && mode=0711
        install -d -m "$mode" "$p" || die "creating ${p} failed"
      fi
      [[ -d $p && ! -L $p ]] || die "${p} is not a directory (a symlink?): nothing written"
      [[ "$(stat -c %u "$p" 2>/dev/null || stat -f %u "$p")" == "$owner" ]] || die "${p} is not owned by uid ${owner}: nothing written"
      if [[ $p == "$keyRoot" ]]; then chmod 0711 "$p" || die "making ${p} 0711 failed"; fi
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
    : "generating host-${machine}@${slot}"
    born
    printf '[ndh-host-key-generate] host-%s@%s generated at %s\n' "$machine" "$slot" "$keyFile" >&2
  fi
  [[ -f $keyFile && ! -L $keyFile ]] || die "${keyFile} is not a regular file"

  public="$(public_of "$keyFile")" || die "${keyFile} is not a readable ed25519 private"
  [[ $public == ssh-ed25519\ * ]] || die "${keyFile} is not an ed25519 key"

  if [[ $bootstrap == console || $bootstrap == tailnet ]]; then
    : "a bootstrap: no old key vouches; the public alone, its binding the operator's witness layer (§o)"
    work="$(mktemp -d "${publishDir}/.publish.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    printf '%s\n' "$public" >"$work/public"
    chmod 0644 "$work/public"
    mv -f "$work/public" "${publishDir}/host-${machine}@${slot}.public"
    rm -f "${publishDir}/host-${machine}@${slot}".statement{,.sig}
    rm -rf "$work"
    trap - EXIT
    local line
    line=$(printf '[ndh-host-key-generate] host-%s@%s born; tape-la à keys-reconcile window: %s' "$machine" "$slot" \
      "$(ssh-keygen -lf "${publishDir}/host-${machine}@${slot}.public" | cut -d' ' -f2)")
    printf '%s\n' "$line" >&2
    : "the console line is a convenience for the operator's eyes; a console that refuses it changes nothing"
    { printf '%s\n' "$line" >>"$console"; } 2>/dev/null || true
    return 0
  fi

  : "F1: the key sshd serves, the one keys.yaml records, vouches for the new public"
  [[ -s $oldKey ]] || die "no old host key at ${oldKey} to sign the new public with"
  [[ "$(public_of "$oldKey")" == "$oldPublic" ]] ||
    die "${oldKey} is not the host key keys.yaml records for ${machine}: nothing published"

  work="$(mktemp -d "${publishDir}/.publish.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  printf 'seedmatic-rotate v1\nname host-%s\nslot %s\nkey %s\n' "$machine" "$slot" "$public" >"$work/statement"
  ssh-keygen -q -Y sign -f "$oldKey" -n seedmatic-rotate "$work/statement" </dev/null || die "signing the statement failed"
  printf '%s\n' "$public" >"$work/public"
  chmod 0644 "$work/public" "$work/statement" "$work/statement.sig"
  for f in public statement statement.sig; do mv -f "$work/$f" "${publishDir}/host-${machine}@${slot}.${f}"; done
  rm -rf "$work"
  trap - EXIT
  printf '[ndh-host-key-generate] host-%s@%s published: %s\n' "$machine" "$slot" "$(ssh-keygen -lf "${publishDir}/host-${machine}@${slot}.public" | cut -d' ' -f2)" >&2
}

ndh::logger:command:run host-key.generate main "$@"
