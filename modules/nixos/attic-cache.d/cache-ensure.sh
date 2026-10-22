# The private cache, created once and reconfigured at every start, through a token minted here for
# this run only and never written outside a private temporary directory.
#
# Its signing key is generated here, inside the cache container, and named <key name>
# (seedmatic-<metalspace>-attic-<n>, as catalog/private-caches.nix accepts it): attic names a key it
# generates after the CACHE, and its CLI only generates, so the cache is created with ours through
# attic's API, on loopback. A cache found under another key name gets a new key the same way. Neither
# the token nor the key is ever an argument, which /proc shows, nor printed.
#
# The cache's PUBLIC key, once right, is written to <public file>, on the disk device this container shares with
# its NixOS guest: the guest signs and publishes it for the seat to collect (keys-reconcile, class attic-cache-key).
usage="usage: attic-cache-ensure <cache> <key name> <retention> <server> <public file> [upstream key name]..."
cache="${1:?$usage}"
keyName="${2:?$usage}"
retention="${3:?$usage}"
server="${4:?$usage}"
publicFile="${5:?$usage}"
shift 5

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work" XDG_CONFIG_HOME="$work/config"

# The token goes from atticadm to a file and is read from it: never an argument, which /proc shows.
atticd-atticadm make-token --sub ndh-cache-ensure --validity '10 minutes' \
  --pull "$cache" --create-cache "$cache" --configure-cache "$cache" \
  --configure-cache-retention "$cache" >"$work/token"
mkdir -p "$XDG_CONFIG_HOME/attic"
cat >"$XDG_CONFIG_HOME/attic/config.toml" <<EOF
default-server = "local"

[servers.local]
endpoint = "$server"
token-file = "$work/token"
EOF
# The same token as a header file for curl, file to file: an expansion of it would be traced, `cat` copies it.
{
  printf 'Authorization: Bearer '
  cat "$work/token"
} >"$work/auth"

upstream=()
for name in "$@"; do
  upstream+=(--upstream-cache-key-name "$name")
done

# set_keypair <POST|PATCH>: a new key named $keyName, generated here, given to the cache — created with
# it (POST, private, as the CLI's defaults) or rekeyed (PATCH). The secret lives in $work only.
set_keypair() {
  nix --extra-experimental-features nix-command key generate-secret --key-name "$keyName" >"$work/key"
  # yq reads the key from its file (load_str): never an argument, an environment variable or a trace.
  if [ "$1" = POST ]; then
    KEY_FILE="$work/key" yq -n -o=json -I=0 \
      '{"keypair": {"Keypair": (load_str(strenv(KEY_FILE)) | sub("\n$"; ""))}, "is_public": false, "store_dir": "/nix/store", "priority": 41, "upstream_cache_key_names": []}'
  else
    KEY_FILE="$work/key" yq -n -o=json -I=0 '{"keypair": {"Keypair": (load_str(strenv(KEY_FILE)) | sub("\n$"; ""))}}'
  fi >"$work/request.json"
  rm -f "$work/key"
  curl -fsS -X "$1" -H "@$work/auth" -H 'Content-Type: application/json' \
    --data-binary "@$work/request.json" "$server/_api/v1/cache-config/$cache" >/dev/null
  rm -f "$work/request.json"
}

if ! attic cache info "$cache" >/dev/null 2>&1; then
  # Private: every read needs a token.
  set_keypair POST
fi
# --retention-period is always passed: a configure without it resets the cache to the global one.
attic cache configure "$cache" --private --retention-period "$retention" "${upstream[@]}"

# attic prints the cache's description on stderr.
info="$(attic cache info "$cache" 2>&1)"
grep -q 'Public: false' <<<"$info" || {
  echo "attic-cache-ensure: $cache is public — refusing to leave it so" >&2
  exit 1
}
named="$(sed -n 's/^.*Public Key: \([^:]*\):.*$/\1/p' <<<"$info")"
if [ "$named" != "$keyName" ]; then
  echo "attic-cache-ensure: $cache's key is named ${named:-nothing}, not $keyName — a new key, generated here" >&2
  set_keypair PATCH
  info="$(attic cache info "$cache" 2>&1)"
  grep -q "Public Key: $keyName:" <<<"$info" || {
    echo "attic-cache-ensure: $cache's key is still not named $keyName — refusing" >&2
    exit 1
  }
fi
grep 'Public Key:' <<<"$info"
public="$(sed -n 's/^.*Public Key: \([^ ]*\)$/\1/p' <<<"$info")"
# By a rename: the guest never reads a half-written public.
printf '%s\n' "$public" >"$work/public"
chmod 0644 "$work/public"
mv -f "$work/public" "$publicFile"
