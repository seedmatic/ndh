# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles cache tokens, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles cache tokens" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset BASH_XTRACEFD 2>/dev/null || true

# ndh-attic-tokens-unseal — this machine's attic tokens, kept at rest as age ciphertext in $store (one
# netrc.<metalspace>.age per cache it reads, write.token.age for its own), decrypted into the tmpfs paths the
# attic client reads: the netrc, every cache's fragment in one file, root 0400, and the write token, 0400 to
# the account its watch-store runs as (writeTokenOwner), each put in place by a rename. Run at every boot, since those paths are gone at boot (roles × keys ⑤). Each item is
# decrypted by this machine's identity and its clear text checked for its shape (a netrc fragment naming the
# cache the catalog gives that metalspace, then a JWT; the write token, a JWT) before anything is put in place.
# An item that does not decrypt or check falls back to its previous generation (`<item>.prev`, which the
# delivery keeps), loudly; with neither, the run fails and the tokens in place stay as they are. Nothing it
# decrypts is ever printed.
#
# Header, fixed at evaluation: store, dir, netrc, writeToken, identityMode (keyfile: an age identity file;
# hostkey: an ssh host key, converted in memory), identity, writeTokenOwner, cacheFqdn (metalspace → its cache's
# fabric name).

umask 077
shopt -s nullglob
log() { printf '[ndh-attic-tokens] %s\n' "$*" >&2; }
die() {
  printf '[ndh-attic-tokens] ERROR: %s — nothing put in place\n' "$*" >&2
  exit 1
}

fragments=("$store"/netrc.*.age)
if ((${#fragments[@]} == 0)) && [[ ! -e "$store/write.token.age" ]]; then
  log "no token delivered in ${store}: nothing to unseal"
  exit 0
fi

decrypt() { # <ciphertext> → its clear text on stdout
  case $identityMode in
    keyfile) age -d -i "$identity" "$1" ;;
    hostkey) age -d -i <(ssh-to-age -private-key -i "$identity") "$1" ;;
  esac
}
jwt='^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'
valid() { # <clear file> <kind: read <fqdn> | write> — with or without a final newline
  local -a line
  mapfile -t line <"$1"
  if [[ $2 == write ]]; then
    ((${#line[@]} == 1)) && [[ ${line[0]} =~ $jwt ]]
  else
    ((${#line[@]} == 2)) && [[ ${line[0]} == "machine $3" && ${line[1]} == "password "* && ${line[1]#password } =~ $jwt ]]
  fi
}
# <ciphertext> <kind> [fqdn] → the clear text in $stage/item: the current generation, else the previous one
unseal() {
  local generation
  for generation in "$1" "$1.prev"; do
    [[ -e $generation ]] || continue
    if decrypt "$generation" >"$stage/item" 2>/dev/null && valid "$stage/item" "${@:2}"; then
      [[ $generation == "$1" ]] || log "WARNING: ${1##*/} does not decrypt or check; its previous generation is used"
      return 0
    fi
  done
  return 1
}

# An owner other than root reads its token through the dir, never lists it.
if [[ $writeTokenOwner == root ]]; then dirMode=0700; else dirMode=0711; fi
install -d -m "$dirMode" "$dir"
stage="$(mktemp -d "${dir}/.unseal.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
: >"$stage/netrc"
caches=()
for fragment in "${fragments[@]}"; do
  metalspace="${fragment##*/netrc.}"
  metalspace="${metalspace%.age}"
  [[ -v "cacheFqdn[$metalspace]" ]] || die "${fragment##*/}: no metalspace ${metalspace} in the catalog"
  unseal "$fragment" read "${cacheFqdn[$metalspace]}" ||
    die "${fragment##*/}: neither it nor its previous generation decrypts to a netrc fragment for ${cacheFqdn[$metalspace]}"
  { cat "$stage/item" && printf '\n'; } >>"$stage/netrc"
  caches+=("${cacheFqdn[$metalspace]}")
done
if [[ -e "$store/write.token.age" ]]; then
  unseal "$store/write.token.age" write ||
    die "write.token.age: neither it nor its previous generation decrypts to a token"
  mv "$stage/item" "$stage/write.token"
fi
rm -f "$stage/item"

chmod 0400 "$stage"/*
[[ $writeTokenOwner == root || ! -e "$stage/write.token" ]] || chown "$writeTokenOwner" "$stage/write.token"
mv -f "$stage/netrc" "$netrc"
[[ ! -e "$stage/write.token" ]] || mv -f "$stage/write.token" "$writeToken"
log "unsealed the read tokens of ${caches[*]:-no cache}$([[ -e "$store/write.token.age" ]] && echo ", and the write token")"
