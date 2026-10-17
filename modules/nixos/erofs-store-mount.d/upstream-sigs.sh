# Give the EROFS layers' upstream paths back their own signatures. The layers' DB is loaded from an
# unsigned registration, so a path cache.nixos.org serves (glibc, bash, …) sits in the store with NO
# signature (measured on the probe and bioskop-nixos, 2026-10-17), and attic's upload filter, which
# compares local key names only, cannot skip it: a watch-store would push the whole base system.
#
# Nothing is signed here: `nix store copy-sigs` only copies the signatures the substituter holds,
# and only onto a path whose narHash, size and references equal its own. Our own builds in the
# layers stay unsigned (cache.nixos.org does not serve them); they wait for the layer key.
#
# Idempotent and best-effort: a layer set already done is skipped, and an unreachable substituter is
# a warning, never a failed boot — the next boot tries again.
# Usage: upstream-sigs <substituter> <stamp file> <layer dir>...
substituter="${1:?usage: upstream-sigs <substituter> <stamp file> <layer dir>...}"
stamp="${2:?usage: upstream-sigs <substituter> <stamp file> <layer dir>...}"
shift 2

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for layer in "$@"; do
  find "$layer" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '/nix/store/%f\n'
done | sort -u >"$work/layer-paths"
layer_set="$(printf '%s\n' "$substituter" "$@" | cat - "$work/layer-paths" | sha256sum | cut -c1-16)"
if [ -s "$stamp" ] && [ "$(cat "$stamp")" = "$layer_set" ]; then
  echo "upstream-sigs: layer set $layer_set already done"
  exit 0
fi

unsigned() { # the layer paths valid in this store and carrying no signature
  nix path-info --sigs --stdin <"$work/layer-paths" 2>/dev/null | awk -F'\t' 'NF < 2 || $2 == "" { print $1 }'
}
unsigned >"$work/before"
echo "upstream-sigs: $(wc -l <"$work/layer-paths") layer paths, $(wc -l <"$work/before") without a signature"

if [ -s "$work/before" ] && ! nix store copy-sigs --substituter "$substituter" --stdin <"$work/before" 2>"$work/err"; then
  echo "upstream-sigs: WARN: could not copy signatures from $substituter ($(tail -1 "$work/err")) — the next boot tries again" >&2
  exit 0
fi

unsigned >"$work/after"
echo "upstream-sigs: $(($(wc -l <"$work/before") - $(wc -l <"$work/after"))) given back their signature from $substituter; $(wc -l <"$work/after") stay unsigned (ours, or not served there)"
mkdir -p "$(dirname "$stamp")"
echo "$layer_set" >"$stamp"
