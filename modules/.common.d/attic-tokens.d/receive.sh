# ndh-attic-tokens-receive — this machine's side of the attic token deposit (roles × keys ⑤): reads a frame on
# stdin, keeps each item at rest in $store, then unseals them. The items are age ciphertext sealed to this
# machine's identity, so the frame carries nothing in clear, and nothing here decrypts: the unseal does, and
# keeps the tokens in place when a deposit does not check.
#
#   ndh-attic-tokens/1 <machine>
#   item <name> <base64 of the age file>     one per item: netrc.<metalspace>.age, write.token.age
#   end
#
# Each item must be named for a cache the catalog names (or be the write token), carry an age header with an
# X25519 stanza, and stay within the size bound. The previous generation of each item is kept as <item>.prev
# (one generation); the new one is put in place by a rename. Any fault writes nothing.
#
# Header, fixed at evaluation: machine, store, maxBytes, unseal (its store path), cacheFqdn.

umask 077
log() { printf '[ndh-attic-tokens-receive] %s\n' "$*" >&2; }
refuse() {
  printf '[ndh-attic-tokens-receive] ERROR: %s — refused, nothing written\n' "$1" >&2
  exit 1
}

frame="$(head -c "$((maxBytes + 1))")"
((${#frame} <= maxBytes)) || refuse "a frame over ${maxBytes} bytes"
mapfile -t lines <<<"$frame"
unset frame
n=${#lines[@]}
((n >= 3)) || refuse "a malformed frame"
[[ ${lines[0]} == "ndh-attic-tokens/1 ${machine}" ]] || refuse "a frame not addressed to ${machine}"
[[ ${lines[n - 1]} == end ]] || refuse "a malformed frame end"

install -d -m 0700 "$store"
stage="$(mktemp -d "${store}/.receive.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
names=()
for ((i = 1; i < n - 1; i++)); do
  read -r word name data rest <<<"${lines[i]}"
  [[ $word == item && -n $name && -n $data && -z $rest ]] || refuse "line $i is no item"
  if [[ $name =~ ^netrc\.([a-z0-9-]+)\.age$ ]]; then
    [[ -v "cacheFqdn[${BASH_REMATCH[1]}]" ]] || refuse "${name}: no metalspace ${BASH_REMATCH[1]} in the catalog"
  elif [[ $name != write.token.age ]]; then
    refuse "${name}: not a token item"
  fi
  [[ " ${names[*]} " != *" ${name} "* ]] || refuse "${name} twice"
  printf '%s' "$data" | base64 -d >"$stage/$name" 2>/dev/null || refuse "${name} is not base64"
  { read -r header && read -r stanza; } <"$stage/$name" || refuse "${name} is not an age file"
  [[ $header == age-encryption.org/v1 && $stanza == "-> X25519 "* ]] || refuse "${name} is not age ciphertext to an X25519 identity"
  names+=("$name")
done
unset lines

for name in "${names[@]}"; do
  [[ ! -e "$store/$name" ]] || mv -f "$store/$name" "$store/$name.prev"
  mv -f "$stage/$name" "$store/$name"
done
log "kept ${names[*]} in ${store} (each previous one as .prev)"
"$unseal"
