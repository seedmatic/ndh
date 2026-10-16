# The private cache, created once and reconfigured at every start, through a token minted here for
# this run only and never written outside a private temporary directory.
cache="${1:?usage: attic-cache-ensure <cache> <retention> <server> [upstream key name]...}"
retention="${2:?usage: attic-cache-ensure <cache> <retention> <server> [upstream key name]...}"
server="${3:?usage: attic-cache-ensure <cache> <retention> <server> [upstream key name]...}"
shift 3

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

upstream=()
for name in "$@"; do
  upstream+=(--upstream-cache-key-name "$name")
done

if ! attic cache info "$cache" >/dev/null 2>&1; then
  # Without --public: every read needs a token.
  attic cache create "$cache"
fi
# --retention-period is always passed: a configure without it resets the cache to the global one.
attic cache configure "$cache" --private --retention-period "$retention" "${upstream[@]}"

# attic prints the cache's description on stderr.
info="$(attic cache info "$cache" 2>&1)"
grep -q 'Public: false' <<<"$info" || {
  echo "attic-cache-ensure: $cache is public — refusing to leave it so" >&2
  exit 1
}
grep 'Public Key:' <<<"$info"
