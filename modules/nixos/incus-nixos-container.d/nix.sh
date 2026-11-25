nix:profile:list() {
  local profiles
  profiles=$(yq -p json -oy -r '(.profiles // {}) | to_entries | .[] | .key + "\t" + .value' <<<"$1") || return 1
  printf '/nix/var/nix/profiles/system\t%s\n%s\n' "$(util:field "$1" toplevel)" "$profiles"
}

nix:profile:check() {
  local info dir profiles profile package ok=0
  info=$(incus:instance "$1") || return 1
  eval "$(yq -p json -o=shell '{"dir": .dir} | with_entries(.value = (.value // ""))' <<<"$info")"
  profiles=$(nix:profile:list "$info") || return 1
  while IFS=$'\t' read -r profile package; do
    [ -n "$profile" ] || continue
    if [ "$(readlink -f "$dir/root$profile" 2>/dev/null || true)" != "$(readlink -f "$package")" ]; then
      echo "$profile is not $package"
      ok=1
    fi
  done <<<"$profiles"
  return "$ok"
}

