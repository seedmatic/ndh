# keys-reconcile's row for the attic-cache-key class (F3): a metalspace's cache public, which its NixOS guest publishes
# (modules/nixos/attic-cache.d/publish.sh) as attic-<metalspace>.cache-key.{public,statement,statement.sig} in its
# attic published directory, signed with the host key it serves. Sourced by keys-reconcile.sh beside the host-key row.
#
# A batch entry of this class, frozen at evaluation: { class, machine (the guest), cache (its metalspace), keyNameRegex
# (the catalog's keyNamePattern for it), servingPublic (the guest's serving host-key public keys.json records), dir
# (its attic published directory) }. Trusted: the batch. Not trusted: anything collected.

reconcile::attic-cache-key::collect() { # <batch index> <into dir>
  local cache
  cache=$(yq -r -p json -o json ".[$1].cache" "$batch")
  fetch "$(yq -r -p json -o json ".[$1].machine" "$batch")" "$(yq -r -p json -o json ".[$1].dir" "$batch")" "$2" \
    "attic-${cache}".cache-key.{public,statement,statement.sig}
}

# reconcile::attic-cache-key::verify <dir> <machine> <cache> <keyNameRegex> <servingPublic>: the collected publication,
# checked against what ndh RECORDS (the guest's serving host-key public), never against anything published beside
# it; prints the verified cache public, or refuses with the reason and returns non-zero.
reconcile::attic-cache-key::verify() {
  local dir="$1" machine="$2" cache="$3" keyNameRegex="$4" servingPublic="$5"
  local stem="${dir}/attic-${cache}.cache-key" public allowed f
  for f in public statement statement.sig; do
    [[ -f "${stem}.${f}" && ! -L "${stem}.${f}" ]] || { reconcile::refuse "attic-${cache}: ${f} was not published"; return 1; }
  done
  public="$(<"${stem}.public")"
  [[ $public =~ ^${keyNameRegex}:[A-Za-z0-9+/]{43}=$ ]] ||
    { reconcile::refuse "attic-${cache}: its published public is not one ${cache} cache key named as the catalog accepts it"; return 1; }
  [[ "$(<"${stem}.statement")" == "$(printf 'seedmatic-attic v1\nclass attic-cache-key\ncache %s\nmachine %s\nsha256 %s' \
    "$cache" "$machine" "$(sha256sum "${stem}.public" | cut -d' ' -f1)")" ]] ||
    { reconcile::refuse "attic-${cache}: its statement does not name this class, cache, guest and public"; return 1; }
  [[ -n $servingPublic ]] || { reconcile::refuse "attic-${cache}: keys.yaml records no serving host key for ${machine}"; return 1; }
  allowed="$(mktemp)"
  printf 'host-%s %s\n' "$machine" "$servingPublic" >"$allowed"
  if ! ssh-keygen -q -Y verify -f "$allowed" -I "host-${machine}" -n seedmatic-attic -s "${stem}.statement.sig" <"${stem}.statement" >/dev/null 2>&1; then
    rm -f "$allowed"
    reconcile::refuse "attic-${cache}: its statement is not signed by the host key keys.yaml records as ${machine}'s serving one"
    return 1
  fi
  rm -f "$allowed"
  printf '%s\n' "$public"
}

reconcile::attic-cache-key::measure() { # <batch index> <work dir>
  local i="$1" work="$2" machine cache public
  machine=$(yq -r -p json -o json ".[$i].machine" "$batch")
  cache=$(yq -r -p json -o json ".[$i].cache" "$batch")
  reconcile::attic-cache-key::collect "$i" "$work"
  if public=$(reconcile::attic-cache-key::verify "$work" "$machine" "$cache" \
    "$(yq -r -p json -o json ".[$i].keyNameRegex" "$batch")" "$(yq -r -p json -o json ".[$i].servingPublic" "$batch")" 2>"$work/why"); then
    printf '  ✓ %s — cache %s : %s\n' "$machine" "$cache" "$public"
    printf '      entrée privateCaches.%s à enregistrer (acceptée par darwin et nixos)\n' "$cache"
    printf '%s\t%s\t%s\t%s\n' "$i" "$cache" "$public" \
      "$(cat "$work/attic-${cache}".cache-key.{public,statement,statement.sig} | sha256sum | cut -d' ' -f1)" >>"$work/attic-cache-key.measured"
  else
    printf '  ✗ %s — cache %s : %s\n' "$machine" "$cache" "$(sed 's/^\[keys-reconcile\] refused: //' "$work/why")"
    return 1
  fi
}

reconcile::attic-cache-key::recheck() { # <work dir> <again dir>
  local i cache public hash
  [[ -s "$1/attic-cache-key.measured" ]] || return 0
  while IFS=$'\t' read -r i cache public hash; do
    reconcile::attic-cache-key::collect "$i" "$2"
    [[ "$(cat "$2/attic-${cache}".cache-key.{public,statement,statement.sig} 2>/dev/null | sha256sum | cut -d' ' -f1)" == "$hash" ]] ||
      die "attic-${cache}: its publication changed since it was measured: nothing written"
  done <"$1/attic-cache-key.measured"
}

# The window's write: each measured cache public becomes one entry of catalog/private-caches.json, written as data with
# yq (never Nix syntax), and its statement and signature are committed beside it, under
# catalog/private-caches.d/statements/, for the build check that re-verifies every entry against the guest's recorded
# key. Refused, nothing committed, unless the file is the input plus exactly these entries.
reconcile::attic-cache-key::write() { # <work dir>
  local work="$1" i cache public hash fqdn day f entries="$tree/catalog/private-caches.json" statements="$tree/catalog/private-caches.d/statements"
  [[ -s "$work/attic-cache-key.measured" ]] || return 0
  day="$(date -u +%Y-%m-%d)"
  [[ -f $entries ]] || reconcile::fail "catalog/private-caches.json is missing at ${revision:0:12}" || return 1
  cp "$entries" "$work/attic-expected.json"
  mkdir -p "$statements"
  while IFS=$'\t' read -r i cache public hash; do
    : "attic-${cache}: refused if the revision already records a cache key for it (a rotation is declared, never observed)"
    [[ "$(C="$cache" yq -p json -o json '.[strenv(C)] // null' "$entries")" == null ]] ||
      reconcile::fail "catalog privateCaches.${cache} already records a key: a new one is a declared rotation, not a window's" || return 1
    fqdn="$(yq -r -p json -o json ".[$i].fqdn" "$batch")"
    for f in "$entries" "$work/attic-expected.json"; do
      C="$cache" P="$public" F="$fqdn" D="$day" R="$revision" \
        yq -i -p json -o json '.[strenv(C)] = {"publicKey": strenv(P), "consumers": [strenv(F)], "acceptedBy": ["darwin", "nixos"],
          "accepted": {"date": strenv(D)}, "origin": {"revision": strenv(R)}, "lifecycle": "permanent"}' "$f"
    done
    cp "$work/attic-${cache}.cache-key.statement" "$work/attic-${cache}.cache-key.statement.sig" "$statements/"
    printf '%s\n' "catalog/private-caches.d/statements/attic-${cache}.cache-key.statement" \
      "catalog/private-caches.d/statements/attic-${cache}.cache-key.statement.sig" >>"$work/staged"
    printf '      privateCaches.%s enregistrée : %s\n' "$cache" "$public"
  done <"$work/attic-cache-key.measured"

  printf '%s\n' catalog/private-caches.json >>"$work/staged"
  printf '\nkeys-reconcile: record %s attic cache key(s) at %s\n\n%s\n' "$(wc -l <"$work/attic-cache-key.measured")" "${revision:0:12}" \
    "$(cut -f2 "$work/attic-cache-key.measured")" >>"$work/summary"
}

# Its postcondition, run by the window after every class wrote: the entries are the input plus exactly the ones this
# window set, and every entry has its statement pair and every statement pair its entry.
reconcile::attic-cache-key::check() { # <work dir>
  local entries="$tree/catalog/private-caches.json" statements="$tree/catalog/private-caches.d/statements" ms f
  [[ -s "$1/attic-cache-key.measured" ]] || return 0
  [[ "$(yq -p json -o json -S . "$entries")" == "$(yq -p json -o json -S . "$1/attic-expected.json")" ]] ||
    reconcile::fail "catalog/private-caches.json changed more than the entries this window set" || return 1
  for ms in $(yq -r -p json -o json 'keys | .[]' "$entries"); do
    [[ -f "$statements/attic-${ms}.cache-key.statement" && -f "$statements/attic-${ms}.cache-key.statement.sig" ]] ||
      reconcile::fail "privateCaches.${ms} has no statement pair beside it" || return 1
  done
  for f in "$statements"/*.cache-key.statement; do
    [[ -e $f ]] || continue
    ms="$(basename "$f" .cache-key.statement)"
    ms="${ms#attic-}"
    [[ "$(C="$ms" yq -p json -o json '.[strenv(C)] // null' "$entries")" != null ]] ||
      reconcile::fail "a statement for ${ms}, which catalog/private-caches.json does not hold" || return 1
  done
}
