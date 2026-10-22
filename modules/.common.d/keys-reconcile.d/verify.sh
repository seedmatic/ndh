# keys-reconcile's verification of ONE machine's publication (roles × keys K4, F1 and F2), sourced by plan and apply.
# It reads three files a machine published (K3: host-<m>@<slot>.{public,statement,statement.sig}), as collected by
# the seat into a directory, and trusts none of them: the statement must be signed by the machine's RECORDED old
# public (keys.yaml's current slot), in namespace seedmatic-rotate, and must name exactly this key, this slot and the
# public published beside it; the public must be new to the whole fleet, recorded or retired.
#
#   reconcile::verify <dir> <key> <slot> <recorded old public> <every public keys.json holds, one per line>
# prints the verified public on stdout, or refuses on stderr with the reason, and returns non-zero.

reconcile::refuse() {
  printf '[keys-reconcile] refused: %s\n' "$*" >&2
  return 1
}

reconcile::verify() {
  local dir="$1" keyName="$2" slot="$3" oldPublic="$4" known="$5"
  local stem="${dir}/${keyName}@${slot}" public allowed

  for f in public statement statement.sig; do
    [[ -f "${stem}.${f}" && ! -L "${stem}.${f}" ]] || { reconcile::refuse "${keyName}@${slot}: ${f} was not published"; return 1; }
  done
  public="$(<"${stem}.public")"
  [[ $public =~ ^ssh-ed25519\ [A-Za-z0-9+/]{68}$ ]] ||
    { reconcile::refuse "${keyName}@${slot}: its published public is not one ed25519 public"; return 1; }

  : "F1: the statement names this key, this slot and this public, and the RECORDED old public signed it"
  [[ "$(<"${stem}.statement")" == "$(printf 'seedmatic-rotate v1\nname %s\nslot %s\nkey %s' "$keyName" "$slot" "$public")" ]] ||
    { reconcile::refuse "${keyName}@${slot}: its statement does not name this key, slot and public"; return 1; }
  [[ -n $oldPublic ]] || { reconcile::refuse "${keyName}: keys.yaml records no old public to verify the statement with"; return 1; }
  allowed="$(mktemp)"
  printf '%s %s\n' "$keyName" "$oldPublic" >"$allowed"
  if ! ssh-keygen -q -Y verify -f "$allowed" -I "$keyName" -n seedmatic-rotate -s "${stem}.statement.sig" <"${stem}.statement" >/dev/null 2>&1; then
    rm -f "$allowed"
    reconcile::refuse "${keyName}@${slot}: its statement is not signed by the old public keys.yaml records"
    return 1
  fi
  rm -f "$allowed"

  : "F2: a public new to the fleet, never one any slot, authority or revocation holds"
  if grep -qxF -- "${public#ssh-ed25519 }" <<<"$known"; then
    reconcile::refuse "${keyName}@${slot}: its public is already in keys.yaml (recorded, or revoked): no reuse"
    return 1
  fi
  printf '%s\n' "$public"
}
