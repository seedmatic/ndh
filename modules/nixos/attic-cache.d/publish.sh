#!/usr/bin/env -S bash -euo pipefail
# @codebase
# ndh-attic-publish: this NixOS guest publishes what its cache container produced, for the seat to collect
# (keys-reconcile): the cache's public key (class attic-cache-key) and the CSR of its TLS key (class attic-tls-csr).
# Rendered by pkgs.replaceVars, each value shell-quoted: machine, cache, fqdn (the cache's fabric name), keyNameRegex
# (the catalog's keyNamePattern for this metalspace), sharedPublic and sharedCsr (the files the container writes on the
# disk device it shares with this guest), base (the root of the directory walk), owner (0: root), publishDir, hostKey
# (the key this guest's sshd serves, whose certificate keys.yaml records).
#
# The shared files are HOSTILE input: the container's root writes them. Each is read only if it is a regular file, not
# a link, and only its first bytes, into this run's own directory; that copy is the one checked, hashed and signed, so
# the container cannot swap a file between the check and the signature. Each statement binds its artifact to THIS
# guest (namespace seedmatic-attic), not to the container: root in the container can hand any well-formed artifact.
#
# Idempotent, at every activation and on every write of a shared file: the same content re-signs to the same files.
# Prints names, the cache, the public and the CSR's name only.
source @nixBashTrampoline@

readonly machine=@machine@ cache=@cache@ fqdn=@fqdn@ keyNameRegex=@keyNameRegex@ sharedPublic=@sharedPublic@ sharedCsr=@sharedCsr@
readonly base=@base@ owner=@owner@ publishDir=@publishDir@ hostKey=@hostKey@

die() {
  printf '[ndh-attic-publish] ERROR: %s\n' "$*" >&2
  exit 1
}

# owned_dirs <dir>…: from $base, every component down to each <dir> is a real directory owned by $owner, not a symlink
# and not group- or world-writable; what is missing is created one component at a time, 0755, so no `install -d` ever
# follows a link planted there.
owned_dirs() {
  local dir p c mode
  local -a rel
  for dir in "$@"; do
    [[ $dir == "$base"/* ]] || die "${dir} is not under ${base}"
    p="$base"
    IFS=/ read -ra rel <<<"${dir#"$base"/}"
    for c in "" "${rel[@]}"; do
      p="$p${c:+/$c}"
      if [[ ! -e $p && ! -L $p ]]; then install -d -m 0755 "$p" || die "creating ${p} failed"; fi
      [[ -d $p && ! -L $p ]] || die "${p} is not a directory (a symlink?): nothing published"
      [[ "$(stat -c %u "$p" 2>/dev/null || stat -f %u "$p")" == "$owner" ]] || die "${p} is not owned by uid ${owner}: nothing published"
      mode="$(stat -c %a "$p" 2>/dev/null || stat -f %Lp "$p")"
      (((8#$mode & 8#022) == 0)) || die "${p} is group- or world-writable (${mode}): nothing published"
    done
  done
}

# take <shared file> <bytes> <copy>: the bounded read of a hostile file into this run's own copy; 1 if it is absent
take() {
  if [[ ! -e $1 && ! -L $1 ]]; then return 1; fi
  [[ -f $1 && ! -L $1 ]] || die "${1} is not a regular file (a symlink?): nothing published"
  head -c "$2" -- "$1" >"$3" || die "reading ${1} failed"
}

# sign <class> <artifact copy> <published stem> <extension>: the statement over the copy's sha256, signed with the key
# this guest serves, then the artifact, its statement and signature put in place by renames
sign() {
  local class="$1" copy="$2" stem="$3" ext="$4" sum
  sum="$(sha256sum "$copy" | cut -d' ' -f1)"
  printf 'seedmatic-attic v1\nclass %s\ncache %s\nmachine %s\nsha256 %s\n' "$class" "$cache" "$machine" "$sum" >"$work/${class}.statement"
  ssh-keygen -q -Y sign -f "$hostKey" -n seedmatic-attic "$work/${class}.statement" </dev/null || die "signing the ${class} statement failed"
  chmod 0644 "$copy" "$work/${class}.statement" "$work/${class}.statement.sig"
  mv -f "$copy" "${stem}.${ext}"
  mv -f "$work/${class}.statement" "${stem}.statement"
  mv -f "$work/${class}.statement.sig" "${stem}.statement.sig"
}

main() {
  umask 022
  owned_dirs "$publishDir"
  work="$(mktemp -d "${publishDir}/.publish.XXXXXX")"
  trap 'rm -rf "$work"' EXIT

  : "the cache's public: one line, named as the catalog accepts it"
  if take "$sharedPublic" 256 "$work/public.read"; then
    local public
    public="$(<"$work/public.read")"
    [[ $public =~ ^${keyNameRegex}:[A-Za-z0-9+/]{43}=$ ]] ||
      die "${sharedPublic} is not one ${cache} public key named as the catalog accepts it: nothing published"
    printf '%s\n' "$public" >"$work/public"
    sign attic-cache-key "$work/public" "${publishDir}/attic-${cache}.cache-key" public
    printf '[ndh-attic-publish] %s public published by %s: %s\n' "$cache" "$machine" "$public" >&2
  else
    printf '[ndh-attic-publish] %s: the container has not written its public yet\n' "$cache" >&2
  fi

  : "the TLS key's CSR: one PEM request, self-signed, naming exactly the cache's fabric name"
  if take "$sharedCsr" 4096 "$work/csr.read"; then
    @openssl@ req -in "$work/csr.read" -noout -verify >/dev/null 2>&1 ||
      die "${sharedCsr} is not one CSR that verifies: nothing published"
    @openssl@ req -in "$work/csr.read" -out "$work/csr" >/dev/null 2>&1 || die "re-encoding ${sharedCsr} failed"
    [[ "$(@openssl@ req -in "$work/csr" -noout -subject -nameopt RFC2253 2>/dev/null)" == "subject=CN=${fqdn}" ]] ||
      die "${sharedCsr}'s subject is not CN=${fqdn}: nothing published"
    sign attic-tls-csr "$work/csr" "${publishDir}/attic-${cache}.tls-csr" csr
    printf '[ndh-attic-publish] %s TLS CSR published by %s: CN=%s\n' "$cache" "$machine" "$fqdn" >&2
  else
    printf '[ndh-attic-publish] %s: the container has not written its CSR yet\n' "$cache" >&2
  fi
  rm -rf "$work"
  trap - EXIT
}

ndh::logger:command:run attic.publish main "$@"
