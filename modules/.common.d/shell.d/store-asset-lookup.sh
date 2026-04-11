#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "@bashTrampoline@"
# shellcheck disable=SC1091
source "@logger@"

usage() {
  cat <<'EOF'
Usage: io.nxmatic.nix-darwin-home-store-asset-lookup <name-or-regex> [--all] [--literal]

Searches /nix/store paths reachable from active system roots and prints matches.
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }

query="$1"
shift

want_all=0
literal_mode=0
if [[ "${1:-}" == "--all" ]]; then
  want_all=1
  shift
fi

if [[ "${1:-}" == "--literal" ]]; then
  literal_mode=1
  shift
fi

[[ $# -eq 0 ]] || { usage >&2; exit 2; }

store_prefix="${NDH_STORE_PREFIX:-@defaultStorePrefix@}"
literal_target="$query"
if [[ "$literal_mode" -eq 1 ]]; then
  if [[ "$literal_target" != "$store_prefix-"* ]]; then
    literal_target="$store_prefix-$literal_target"
  fi
fi

roots=()
[[ -e /run/current-system ]] && roots+=("/run/current-system")
[[ -e /nix/var/nix/profiles/system ]] && roots+=("/nix/var/nix/profiles/system")

[[ ${#roots[@]} -gt 0 ]] || {
  echo "No active system roots found (/run/current-system or /nix/var/nix/profiles/system)." >&2
  exit 1
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for root in "${roots[@]}"; do
  @nix@/bin/nix-store -qR "$root" || true
done |
  @gnugrep@/bin/grep '^/nix/store/' |
  @coreutils@/bin/sort -u >"$tmp"

matches="$({
  while IFS= read -r path; do
    base="${path##*/}"
    if [[ "$literal_mode" -eq 1 ]]; then
      [[ "$base" == "$literal_target" ]] && printf '%s\n' "$path"
    else
      if @gnugrep@/bin/grep -Eiq -- "$query" <<<"$base"; then
        printf '%s\n' "$path"
      fi
    fi
  done <"$tmp"
})"

if [[ -z "$matches" ]]; then
  echo "No asset matched query: $query" >&2
  exit 1
fi

if [[ "$want_all" -eq 1 ]]; then
  printf '%s\n' "$matches"
  exit 0
fi

printf '%s\n' "$matches" | @coreutils@/bin/head -n 1
