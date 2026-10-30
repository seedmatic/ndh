# ndh-attic-tokens-fetch — this machine pulls its own attic tokens from every cache it reads (F6): each cache serves
# them at http://<cache>/tokens/<dir>/, where <dir> is a hash of this machine and its access point's public (fixed at
# evaluation), as age ciphertext sealed to this machine's identity. Each file is fetched in plain HTTP on the fabric (no
# TLS in the lab: the ciphertext is the protection), bounded in size, required to be age, then put in the unseal's
# store by a rename, keeping the previous generation as <item>.prev; the unseal then decrypts and checks them. Nothing
# here decrypts, and nothing in clear is ever fetched.
#
# A cache that does not answer keeps this machine's tokens as they are (they are valid twice the mint period). A
# token older than `staleAfter` days fails the run LOUDLY: the cache has not been reached for one and a half periods.
#
# Header, fixed at evaluation: machine, store, dir, maxBytes, staleAfter (days), unseal
# (its store path), caches (metalspace → its cache's fabric name), own (this machine's metalspace, the one cache that
# also gives it a write token).

umask 077
log() { printf '[ndh-attic-tokens-fetch] %s\n' "$*" >&2; }

[[ $dir =~ ^[0-9a-f]{64}$ ]] || {
  log "ERROR: this machine's token directory is not a sha256: ${dir}"
  exit 1
}
install -d -m 0700 "$store"
stage="$(mktemp -d "${store}/.fetch.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

# get <fqdn> <item>: the file into $stage/<item>, or nothing; 0 if fetched and well-formed
get() {
  local fqdn="$1" item="$2" code
  code="$(curl -sS --proto =http --max-time 30 --max-filesize "$maxBytes" -o "$stage/$item" -w '%{http_code}' \
    "http://${fqdn}/tokens/${dir}/${item}" 2>"$stage/curl.err")" || {
    log "WARNING: ${fqdn} did not answer for ${item}: $(tail -1 "$stage/curl.err")"
    rm -f "$stage/$item"
    return 1
  }
  if [[ $code != 200 ]]; then
    log "WARNING: ${fqdn} answered ${code} for ${item}"
    rm -f "$stage/$item"
    return 1
  fi
  head -c 32 "$stage/$item" | grep -q '^age-encryption.org/v1' || {
    log "ERROR: ${fqdn}'s ${item} is not age ciphertext: refused"
    rm -f "$stage/$item"
    return 1
  }
}

fetched=0 stale=0
for metalspace in "${!caches[@]}"; do
  fqdn="${caches[$metalspace]}"
  items=("netrc.${metalspace}.age")
  [[ $metalspace != "$own" ]] || items+=("write.token.age")
  for item in "${items[@]}"; do
    if get "$fqdn" "$item"; then
      if [[ -e $store/$item ]] && ! cmp -s "$stage/$item" "$store/$item"; then mv -f "$store/$item" "$store/$item.prev"; fi
      mv -f "$stage/$item" "$store/$item"
      fetched=$((fetched + 1))
    elif [[ -n $(find "$store/$item" -mtime +"$staleAfter" 2>/dev/null) || ! -e $store/$item ]]; then
      log "ERROR: ${item} from ${fqdn} is older than ${staleAfter} days, or was never fetched: this machine will lose that cache"
      stale=$((stale + 1))
    fi
  done
done

"$unseal" || exit 1
log "fetched ${fetched} file(s) for ${machine}"
((stale == 0)) || exit 1
