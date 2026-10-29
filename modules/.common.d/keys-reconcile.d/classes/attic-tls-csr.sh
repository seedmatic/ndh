# keys-reconcile's row for the attic-tls-csr class (F2): a metalspace's cache container's TLS leaf, signed here by the
# TLS authority over the CSR its NixOS guest publishes (modules/nixos/attic-cache.d/publish.sh) as
# attic-<metalspace>.tls-csr.{csr,statement,statement.sig}, signed with the host key the guest serves. Sourced by
# keys-reconcile.sh beside the other rows.
#
# A batch entry of this class, frozen at evaluation: { class, machine (the guest), cache (its metalspace), fqdn (the
# cache's fabric name), servingPublic (the guest's serving host-key public keys.json records), dir (its attic
# published directory), recordedLeaf (the store path of the leaf the catalog records, or "") }. Trusted: the batch
# and keys.json (the authority's cleartext ca_crt). Not trusted: anything collected. An entry whose recorded leaf
# chains to the authority's slot and has more than 30 days left is current: nothing to do, nothing collected. The leaf is valid ~10 years (the
# operator's rule: no renewal that waits on their hand); a compromise is handled by rotating the authority's slot.

readonly atticLeafDays=3650

reconcile::attic-tls-csr::collect() { # <batch index> <into dir>
  local cache
  cache=$(yq -r -p json -o json ".[$1].cache" "$batch")
  fetch "$(yq -r -p json -o json ".[$1].machine" "$batch")" "$(yq -r -p json -o json ".[$1].dir" "$batch")" "$2" \
    "attic-${cache}".tls-csr.{csr,statement,statement.sig}
}

# The TLS authority's signing slot, from keys.json's cleartext fields: the oldest not compromised (as attic-leaf-sign
# chose it). Prints `<slot>` and writes its ca_crt to <file>; never decrypts.
reconcile::attic-tls-csr::authority() { # <ca file>
  local authority slot
  authority=$(yq -r -p json -o json '[.authorities | to_entries[] | select(.value.usage // [] | contains(["tls-authority"])) | .key] | .[0]' "$keysJson")
  [[ -n $authority && $authority != null ]] || { reconcile::refuse "keys.json names no tls-authority"; return 1; }
  slot=$(A="$authority" yq -r -p json -o json '.authorities[strenv(A)].slots | to_entries | sort_by(.key) | map(select((.value.compromised // false) | not)) | .[0].key' "$keysJson")
  [[ -n $slot && $slot != null ]] || { reconcile::refuse "${authority} has no slot that may sign"; return 1; }
  A="$authority" S="$slot" yq -r -p json -o json '.authorities[strenv(A)].slots[strenv(S)].ca_crt' "$keysJson" >"$1"
  grep -q '^-----BEGIN CERTIFICATE-----' "$1" || { reconcile::refuse "${authority}@${slot} has no cleartext ca_crt"; return 1; }
  printf '%s %s\n' "$authority" "$slot"
}

sanSet() { # <x509|req> <file> → its SANs, one per line, normalised, sorted
  openssl "$1" -in "$2" -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -1 | tr ',' '\n' |
    sed -e 's/^ *//' -e 's/^DNS://' | sed '/^$/d' | sort -u
}
pubOf() { openssl "$1" -in "$2" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1; }

# reconcile::attic-tls-csr::verify <dir> <machine> <cache> <fqdn> <servingPublic> <recordedPublic>: the collected CSR,
# checked against what ndh RECORDS (the guest's serving host key; the recorded leaf's key, if any); refuses otherwise.
reconcile::attic-tls-csr::verify() {
  local dir="$1" machine="$2" cache="$3" fqdn="$4" servingPublic="$5" recordedPublic="$6"
  local stem="${dir}/attic-${cache}.tls-csr" allowed f
  for f in csr statement statement.sig; do
    [[ -f "${stem}.${f}" && ! -L "${stem}.${f}" ]] || { reconcile::refuse "attic-${cache}: ${f} was not published"; return 1; }
  done
  openssl req -in "${stem}.csr" -noout -verify >/dev/null 2>&1 || { reconcile::refuse "attic-${cache}: its CSR does not verify"; return 1; }
  [[ "$(sanSet req "${stem}.csr")" == "$fqdn" ]] || { reconcile::refuse "attic-${cache}: its CSR does not name exactly ${fqdn}"; return 1; }
  [[ "$(openssl req -in "${stem}.csr" -noout -subject -nameopt RFC2253 2>/dev/null)" == "subject=CN=${fqdn}" ]] ||
    { reconcile::refuse "attic-${cache}: its CSR's subject is not CN=${fqdn}"; return 1; }
  if [[ -n $recordedPublic ]]; then
    [[ "$(pubOf req "${stem}.csr")" == "$recordedPublic" ]] ||
      { reconcile::refuse "attic-${cache}: its CSR's key is not the recorded leaf's key: a new key is a declared rotation"; return 1; }
  fi
  [[ "$(<"${stem}.statement")" == "$(printf 'seedmatic-attic v1\nclass attic-tls-csr\ncache %s\nmachine %s\nsha256 %s' \
    "$cache" "$machine" "$(sha256sum "${stem}.csr" | cut -d' ' -f1)")" ]] ||
    { reconcile::refuse "attic-${cache}: its statement does not name this class, cache, guest and CSR"; return 1; }
  [[ -n $servingPublic ]] || { reconcile::refuse "attic-${cache}: keys.yaml records no serving host key for ${machine}"; return 1; }
  allowed="$(mktemp)"
  printf '%s %s\n' "$machine" "$servingPublic" >"$allowed"
  if ! ssh-keygen -q -Y verify -f "$allowed" -I "${machine}" -n seedmatic-attic -s "${stem}.statement.sig" <"${stem}.statement" >/dev/null 2>&1; then
    rm -f "$allowed"
    reconcile::refuse "attic-${cache}: its statement is not signed by the host key keys.yaml records as ${machine}'s serving one"
    return 1
  fi
  rm -f "$allowed"
}

# current <recorded leaf> <fqdn> <ca file>: 0 when the recorded leaf chains to the slot, names the cache and has more
# than 30 days left; measured on the record, never by probing the cache.
reconcile::attic-tls-csr::current() {
  [[ -n $1 && -f $1 ]] || return 1
  openssl verify -CAfile "$3" -no-CApath -no-CAstore "$1" >/dev/null 2>&1 || return 1
  [[ "$(sanSet x509 "$1")" == "$2" ]] || return 1
  openssl x509 -in "$1" -noout -checkend $((30 * 86400)) >/dev/null 2>&1
}

reconcile::attic-tls-csr::measure() { # <batch index> <work dir>
  local i="$1" work="$2" machine cache fqdn recorded recordedPublic=""
  machine=$(yq -r -p json -o json ".[$i].machine" "$batch")
  cache=$(yq -r -p json -o json ".[$i].cache" "$batch")
  fqdn=$(yq -r -p json -o json ".[$i].fqdn" "$batch")
  recorded=$(yq -r -p json -o json ".[$i].recordedLeaf" "$batch")
  : >"$work/why"
  NDH_RECONCILE_WHY="$work/why" reconcile::attic-tls-csr::authority "$work/ca.crt" >/dev/null ||
    { printf '  ✗ %s — TLS leaf of %s: %s\n' "$machine" "$fqdn" "$(sed 's/^\[keys-reconcile\] refused: //' "$work/why")"; return 1; }
  if reconcile::attic-tls-csr::current "$recorded" "$fqdn" "$work/ca.crt"; then
    printf '  = %s — TLS leaf of %s up to date\n' "$machine" "$fqdn"
    return 0
  fi
  [[ -z $recorded || ! -f $recorded ]] || recordedPublic="$(pubOf x509 "$recorded")"
  reconcile::attic-tls-csr::collect "$i" "$work"
  : >"$work/why"
  if NDH_RECONCILE_WHY="$work/why" reconcile::attic-tls-csr::verify "$work" "$machine" "$cache" "$fqdn" \
    "$(yq -r -p json -o json ".[$i].servingPublic" "$batch")" "$recordedPublic"; then
    printf '  ✓ %s — TLS leaf of %s to sign (%s days)\n' "$machine" "$fqdn" "$atticLeafDays"
    printf '%s\t%s\t%s\t%s\n' "$i" "$cache" "$fqdn" \
      "$(cat "$work/attic-${cache}".tls-csr.{csr,statement,statement.sig} | sha256sum | cut -d' ' -f1)" >>"$work/attic-tls-csr.measured"
  else
    printf '  ✗ %s — TLS leaf of %s: %s\n' "$machine" "$fqdn" "$(sed 's/^\[keys-reconcile\] refused: //' "$work/why")"
    return 1
  fi
}

reconcile::attic-tls-csr::recheck() { # <work dir> <again dir>
  local i cache fqdn hash
  [[ -s "$1/attic-tls-csr.measured" ]] || return 0
  while IFS=$'\t' read -r i cache fqdn hash; do
    reconcile::attic-tls-csr::collect "$i" "$2"
    [[ "$(cat "$2/attic-${cache}".tls-csr.{csr,statement,statement.sig} 2>/dev/null | sha256sum | cut -d' ' -f1)" == "$hash" ]] ||
      die "attic-${cache}: its CSR's publication changed since it was measured: nothing written"
  done <"$1/attic-tls-csr.measured"
}

# The window's write: each measured CSR signed by the TLS authority's signing slot, whose private is decrypted ONLY
# into step's argument through a process substitution, between ndh::secret:begin and :end, never into a variable or a
# file. The pinned leaf profile: digitalSignature alone, serverAuth, never a CA. Written: catalog/attic-leaves/<ms>.crt
# and the CSR's statement pair beside it, for the build check.
reconcile::attic-tls-csr::write() { # <work dir>
  local work="$1" i cache fqdn hash authority slot leaves="$tree/catalog/attic-leaves" rc
  [[ -s "$work/attic-tls-csr.measured" ]] || return 0
  read -r authority slot < <(reconcile::attic-tls-csr::authority "$work/ca.crt") || reconcile::fail "the TLS authority" || return 1
  declare -F ndh::secret:begin >/dev/null && declare -F ndh::secret:end >/dev/null ||
    reconcile::fail "the trampoline has no ndh::secret window: nothing decrypted" || return 1
  cat >"$work/leaf.tpl" <<'TPL'
{
  "subject": {"commonName": {{ toJson .Subject.CommonName }}},
  "sans": {{ toJson .SANs }},
  "keyUsage": ["digitalSignature"],
  "extKeyUsage": ["serverAuth"],
  "basicConstraints": {"isCA": false}
}
TPL
  mkdir -p "$leaves"
  while IFS=$'\t' read -r i cache fqdn hash; do
    rc=0
    ndh::secret:begin "the TLS authority's signing slot, into step's argument, to sign ${fqdn}"
    step certificate sign "$work/attic-${cache}.tls-csr.csr" "$work/ca.crt" \
      <(sops --decrypt --extract "[\"authorities\"][\"${authority}\"][\"slots\"][\"${slot}\"][\"private\"]" \
        "$tree/modules/home-manager/ssh.d/keys.yaml" 2>/dev/null) \
      --template "$work/leaf.tpl" --not-after "$((atticLeafDays * 24))h" >"$work/attic-${cache}.crt" 2>/dev/null || rc=$?
    ndh::secret:end
    ((rc == 0)) || reconcile::fail "step could not sign ${fqdn}'s CSR with ${authority}@${slot} (the operator's sops identity?)" || return 1
    cp "$work/attic-${cache}.crt" "$leaves/${cache}.crt"
    cp "$work/attic-${cache}.tls-csr.statement" "$leaves/${cache}.csr.statement"
    cp "$work/attic-${cache}.tls-csr.statement.sig" "$leaves/${cache}.csr.statement.sig"
    cp "$work/attic-${cache}.tls-csr.csr" "$leaves/${cache}.csr"
    printf '%s\n' "catalog/attic-leaves/${cache}".{crt,csr,csr.statement,csr.statement.sig} >>"$work/staged"
    printf '      TLS leaf of %s signed by %s@%s\n' "$fqdn" "$authority" "$slot"
  done <"$work/attic-tls-csr.measured"
  printf '\nkeys-reconcile: sign %s attic TLS leaf(s) at %s\n\n%s\n' "$(wc -l <"$work/attic-tls-csr.measured")" "${revision:0:12}" \
    "$(cut -f3 "$work/attic-tls-csr.measured")" >>"$work/summary"
}

# Its postcondition, run by the window after every class wrote: each leaf chains to the authority's slot, names exactly
# its cache, is no CA, and carries the key of the CSR it was signed over.
reconcile::attic-tls-csr::check() { # <work dir>
  local i cache fqdn hash leaf
  [[ -s "$1/attic-tls-csr.measured" ]] || return 0
  while IFS=$'\t' read -r i cache fqdn hash; do
    leaf="$tree/catalog/attic-leaves/${cache}.crt"
    openssl verify -CAfile "$1/ca.crt" -no-CApath -no-CAstore "$leaf" >/dev/null 2>&1 ||
      reconcile::fail "${cache}'s leaf does not chain to the TLS authority's slot" || return 1
    [[ "$(sanSet x509 "$leaf")" == "$fqdn" ]] || reconcile::fail "${cache}'s leaf names more or other than ${fqdn}" || return 1
    ! openssl x509 -in "$leaf" -noout -text 2>/dev/null | grep -q 'CA:TRUE' || reconcile::fail "${cache}'s leaf is a CA" || return 1
    [[ "$(pubOf x509 "$leaf")" == "$(pubOf req "$1/attic-${cache}.tls-csr.csr")" ]] ||
      reconcile::fail "${cache}'s leaf does not carry its CSR's key" || return 1
  done <"$1/attic-tls-csr.measured"
}
