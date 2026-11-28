# ndh-attic-tokens-fetch — this machine pulls its own attic tokens from every cache it reads (F6): each cache serves
# them through Incus (`incus file pull` from the cache container's `/var/lib/private/atticd/tokens/<dir>/`), where
# <dir> is a hash of this machine and its access point's public (fixed at evaluation), as age ciphertext sealed to
# this machine's identity. Each file is pulled over the Incus cluster (no HTTP, no TLS needed: the ciphertext is the
# protection), bounded in size, required to be age, then put in the unseal's store by a rename, keeping the previous
# generation as <item>.prev; the unseal then decrypts and checks them. Nothing here decrypts, and nothing in clear is
# ever fetched.
#
# A cache that does not answer keeps this machine's tokens as they are (they are valid twice the mint period). A
# token older than `staleAfter` days fails the run LOUDLY: the cache has not been reached for one and a half periods.
#
# Header, fixed at evaluation: machine, store, dir, maxBytes, staleAfter, unseal (its store path), caches
# (metalspace → its cache's fabric name, unused for the pull but kept for the unseal), own (this machine's
# metalspace, the one cache that also gives it a write token).

umask 077
log() { printf '[ndh-attic-tokens-fetch] %s\n' "$*" >&2; }

[[ $dir =~ ^[0-9a-f]{64}$ ]] || {
  log "ERROR: this machine's token directory is not a sha256: ${dir}"
  exit 1
}
install -d -m 0700 "$store"
stage="$(mktemp -d "${store}/.fetch.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

# get <metalspace> <item>: pull the file into $stage/<item>, or nothing; 0 if fetched and well-formed
get() {
  local ms="$1"
  local item="$2"
  local instance="attic-${ms}"
  if incus file pull --project ndh "${instance}/var/lib/private/atticd/tokens/${dir}/${item}" "$stage/$item" \
       2>"$stage/incus.err"; then
    :
  else
    log "WARNING: ${ms} (${instance}) did not answer for ${item}: $(tail -1 "$stage/incus.err")"
    rm -f "$stage/$item"
    return 1
  fi
  # bound in size
  if [[ $(stat -c %s "$stage/$item" 2>/dev/null || echo 0) -gt $maxBytes ]]; then
    log "ERROR: ${ms}'s ${item} exceeds ${maxBytes} bytes: refused"
    rm -f "$stage/$item"
    return 1
  fi
  head -c 32 "$stage/$item" | grep -q '^age-encryption.org/v1' || {
    log "ERROR: ${ms}'s ${item} is not age ciphertext: refused"
    rm -f "$stage/$item"
    return 1
  }
}

fetched=0 stale=0
for metalspace in "${!caches[@]}"; do
  items=("netrc.${metalspace}.age")
  [[ $metalspace != "$own" ]] || items+=("write.token.age")
  for item in "${items[@]}"; do
    if get "$metalspace" "$item"; then
      if [[ -e $store/$item ]] && ! cmp -s "$stage/$item" "$store/$item"; then mv -f "$store/$item" "$store/$item.prev"; fi
      mv -f "$stage/$item" "$store/$item"
      fetched=$((fetched + 1))
    elif [[ -n $(find "$store/$item" -mtime +"$staleAfter" 2>/dev/null) || ! -e $store/$item ]]; then
      log "ERROR: ${item} from ${metalspace} is older than ${staleAfter} days, or was never fetched: this machine will lose that cache"
      stale=$((stale + 1))
    fi
  done
done

"$unseal" || exit 1
log "fetched ${fetched} file(s) for ${machine}"
((stale == 0)) || exit 1
