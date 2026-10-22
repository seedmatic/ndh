#!/usr/bin/env -S bash -euo pipefail
# @codebase
# ndh-attic-publish: this NixOS guest publishes its cache container's public key for the seat to collect (keys-reconcile,
# class attic-cache-key). Rendered by pkgs.replaceVars, each value shell-quoted: machine, cache, keyNameRegex (the
# catalog's keyNamePattern for this metalspace, anchored), shared (the cache-key.public the container writes on the
# disk device it shares with this guest), base (the root of the directory walk), owner (0: root), publishDir, hostKey
# (the key this guest's sshd serves, whose certificate keys.yaml records).
#
# The shared file is HOSTILE input: the container's root writes it. It is read only if it is a regular file, not a
# link, and only its first bytes, into this run's own directory; that copy is the one checked, hashed and signed, so
# the container cannot swap the file between the check and the signature. The statement binds the public to THIS guest
# (namespace seedmatic-attic), not to the container: root in the container can hand any well-formed public.
#
# Idempotent, at every activation and on every write of the shared file: the same content re-signs to the same files.
# Prints names, the cache and the public only.
source @nixBashTrampoline@

readonly machine=@machine@ cache=@cache@ keyNameRegex=@keyNameRegex@ shared=@shared@
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

main() {
  umask 022
  if [[ ! -e $shared && ! -L $shared ]]; then
    printf '[ndh-attic-publish] %s: the container has not written its public yet; nothing to publish\n' "$cache" >&2
    return 0
  fi
  [[ -f $shared && ! -L $shared ]] || die "${shared} is not a regular file (a symlink?): nothing published"
  owned_dirs "$publishDir"

  work="$(mktemp -d "${publishDir}/.publish.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  : "a bounded read into this run's own copy: what is checked below is what is signed"
  head -c 256 -- "$shared" >"$work/read" || die "reading ${shared} failed"
  local public
  public="$(<"$work/read")"
  [[ $public =~ ^${keyNameRegex}:[A-Za-z0-9+/]{43}=$ ]] ||
    die "${shared} is not one ${cache} public key named as the catalog accepts it: nothing published"
  printf '%s\n' "$public" >"$work/public"

  local sum
  sum="$(sha256sum "$work/public" | cut -d' ' -f1)"
  printf 'seedmatic-attic v1\nclass attic-cache-key\ncache %s\nmachine %s\nsha256 %s\n' "$cache" "$machine" "$sum" >"$work/statement"
  ssh-keygen -q -Y sign -f "$hostKey" -n seedmatic-attic "$work/statement" </dev/null || die "signing the statement failed"
  chmod 0644 "$work/public" "$work/statement" "$work/statement.sig"
  for f in public statement statement.sig; do mv -f "$work/$f" "${publishDir}/attic-${cache}.cache-key.${f}"; done
  rm -rf "$work"
  trap - EXIT
  printf '[ndh-attic-publish] %s published by %s: %s\n' "$cache" "$machine" "$public" >&2
}

ndh::logger:command:run attic.publish main "$@"
