# keys-json — write keys.yaml's public view, keys.json, next to it (public.yq says what it holds and why).
#
#   keys-json <public.yq> <keys.yaml>
#
# Nothing is decrypted: sops leaves the public fields in clear, and public.yq drops every ciphertext. A view that
# would still hold one is refused, and the previous keys.json stays. The file is replaced in one rename.

filter="${1:?usage: keys-json <public.yq> <keys.yaml>}"
yaml="${2:?usage: keys-json <public.yq> <keys.yaml>}"
json="$(dirname "$yaml")/keys.json"

view="$(mktemp "$json.XXXXXX")"
trap 'rm -f "$view"' EXIT
yq -o=json --from-file "$filter" "$yaml" >"$view"
if grep -qF 'ENC[' "$view" || [ "$(yq -r 'has("sops")' "$view")" != false ]; then
  echo "[keys-json] ERROR: the view of $yaml still holds sops data; $json left as it was" >&2
  exit 1
fi
# A private sops left in clear would pass the filter, which drops ciphertexts only: keys.yaml itself is then broken.
if [ "$(yq -r '[.. | select(tag == "!!map") | has("private")] | any' "$view")" != false ] || grep -qF 'PRIVATE KEY' "$view"; then
  echo "[keys-json] ERROR: $yaml holds a private in clear; $json left as it was, re-encrypt keys.yaml first" >&2
  exit 1
fi
chmod 0644 "$view"
mv -f "$view" "$json"
trap - EXIT
