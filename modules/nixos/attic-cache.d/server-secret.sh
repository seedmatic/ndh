# atticd's JWT signing secret, generated once on the cache container's persistent disk. It never
# leaves the container: no sops, no store, never printed. Losing it re-mints every token.
env_file="${1:?usage: attic-server-secret <environment file>}"

if [ -s "$env_file" ]; then
  exit 0
fi

umask 077
tmp="$(mktemp "$env_file.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf 'ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=%s\n' \
  "$(openssl genrsa -traditional 4096 2>/dev/null | base64 -w0)" >"$tmp"
grep -q '^ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=.\{100,\}$' "$tmp" || {
  echo "attic-server-secret: the generated secret is empty or truncated" >&2
  exit 1
}
chmod 0400 "$tmp"
mv "$tmp" "$env_file"
trap - EXIT
echo "attic-server-secret: generated $env_file"
