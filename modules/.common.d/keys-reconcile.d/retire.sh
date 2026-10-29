# keys-reconcile retire <machine> (roles × keys, design « ending a host key's retirement »): end the retirement of a
# machine's host key once its new key serves, in ONE change, as keys.schema.yaml's `revoked` rule has it (« a
# generation enters it in the same change that deletes its slot »). Sourced by keys-reconcile.sh; armed (F3), its
# « yes » on the tty, in the window's worktree discipline.
#
# For host-<machine>: every `retired` slot is DELETED and its `revoked` entry written from that slot's own public.
# And a host certificate recorded on another key (the shared rdp-host's) whose principals name ONLY machines that now
# serve their own key is REMOVED from its slot and its `revoked_certificates` entry written, by its exact key id
# (krl.sh never revokes by serial). krl.sh refuses a revoked id a recorded certificate still shares, so the record
# leaves in the same change.
#
# Refused before the « yes »: host-<machine>'s current slot is not `serving`, or not newer than a retired one; no
# retired slot and no such certificate (nothing to do); a certificate principal that maps to no machine.
# Not checked here, and the operator's step before it: the new key seen served live (keys.yaml cannot know it).

retire::serving() { # <machine>: whether its host key's current slot (the newest neither pending nor retired) serves
  M="$1" yq -e -p json '.keys[strenv(M)].slots // {} | to_entries
    | map(select((.value.state // "") != "pending" and (.value.state // "") != "retired"))
    | sort_by(.key) | .[-1].value.state == "serving"' "$keysJson" >/dev/null 2>&1
}

retire::machines_of() { # <principal>: every machine whose names hold it exactly (contains() would match a substring)
  P="$1" yq -r -p json 'to_entries[] | select(.value | any_c(. == strenv(P))) | .key' "$hostNamesJson"
}

reconcile::retire() { # <machine>
  local machine="$1" keyName current retiredSlots slot cert principals p m answer
  [[ $machine =~ ^[a-z][a-z0-9-]*$ ]] || die "retire: '${machine}' is not a machine name"
  m=$machine yq -e '.[] | select(.name == strenv(m))' "$machines" >/dev/null 2>&1 ||
    die "retire: ${machine} is not in the machine list"
  keyName="${machine}"
  K="$keyName" yq -e -p json '.keys | has(strenv(K))' "$keysJson" >/dev/null 2>&1 ||
    die "retire: keys.yaml has no ${keyName} entry"

  : "the new key must be the one served, and newer than every slot it retires"
  retire::serving "$machine" || die "retire: ${keyName}'s current slot is not serving: switch ${machine} to its new key first"
  current=$(K="$keyName" yq -r -p json '.keys[strenv(K)].slots | to_entries
    | map(select((.value.state // "") != "pending" and (.value.state // "") != "retired")) | sort_by(.key) | .[-1].key' "$keysJson")
  retiredSlots=$(K="$keyName" yq -r -p json '.keys[strenv(K)].slots | to_entries[] | select(.value.state == "retired") | .key' "$keysJson")
  for slot in $retiredSlots; do
    [[ $slot < $current ]] || die "retire: ${keyName}@${slot} is retired but not older than the serving ${current}"
  done

  : "a host certificate on another key, every principal's machine now serving its own key: it is revoked too"
  local -a certs=()
  local certSlots
  : "every key but a machine's own host key (named after its machine)"
  certSlots=$(MACHINES="$(yq -o json -I0 '[.[].name]' "$machines")" yq -r -p json '
    (strenv(MACHINES) | from_json) as $machines | .keys | to_entries[] | select(.key as $n | $machines | any_c(. == $n) | not)
    | .key as $k | .value.slots // {} | to_entries[] | select(.value.certificates) | [$k, .key] | @tsv' "$keysJson") ||
    die "retire: keys.json's certified slots could not be listed"
  while IFS=$'\t' read -r k s; do
    [[ -n $k ]] || continue
    cert=$(K="$k" S="$s" yq -r -p json '.keys[strenv(K)].slots[strenv(S)].certificates[]["ssh-host"] // ""' "$keysJson")
    [[ -n $cert ]] || continue
    principals=$(ssh-keygen -L -f <(printf '%s\n' "$cert") | sed -n '/Principals:/,/Critical Options:/p' | sed '1d;$d' | tr -s ' \n' ' ')
    local names_machine=0 all_own=1
    for p in $principals; do
      m=$(retire::machines_of "$p")
      [[ -n $m ]] || die "retire: ${k}@${s}'s certificate names '${p}', which maps to no machine"
      [[ $m != *$'\n'* ]] || die "retire: ${k}@${s}'s certificate names '${p}', which maps to more than one machine ($(tr '\n' ' ' <<<"$m" | sed 's/ $//'))"
      [[ $m == "$machine" ]] && names_machine=1
      retire::serving "$m" || all_own=0
    done
    ((names_machine && all_own)) && certs+=("${k}@${s}")
  done <<<"$certSlots"

  [[ -n $retiredSlots || ${#certs[@]} -gt 0 ]] || die "retire: ${keyName} has no retired slot and no certificate to revoke"

  echo "retire at revision ${revision:0:12}, in one change:"
  for slot in $retiredSlots; do echo "  ${keyName}@${slot}: slot deleted, its public revoked (revoked)"; done
  for k in "${certs[@]}"; do echo "  ${k}: host certificate removed, revoked by its key id (revoked_certificates)"; done
  printf 'retire and revoke? [yes/no] ' >>"$ttyOut"
  exec 7<"$ttyIn"
  read -r answer <&7 || answer=""
  exec 7<&-
  [[ $answer == yes ]] || { echo "nothing written: the answer is not « yes »"; return 5; }

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  reconcile::tree::open || return 1
  local keysYaml="$tree/modules/home-manager/ssh.d/keys.yaml" public type value id serial
  cp "$keysYaml" "$work/expected.yaml"
  type=$(K="$keyName" yq -r '.keys[strenv(K)].type // "ssh-ed25519"' "$keysYaml")
  for slot in $retiredSlots; do
    public=$(K="$keyName" S="$slot" yq -r '.keys[strenv(K)].slots[strenv(S)].public' "$keysYaml")
    [[ -n $public && $public != null ]] || reconcile::fail "${keyName}@${slot}: a retired slot without a public" || return 1
    value=$(T="$type" P="$public" R="retired after ${keyName}@${current} served (keys-reconcile retire)" \
      yq -n -o json -I0 '{"type": strenv(T), "public": strenv(P), "reason": strenv(R)}')
    reconcile::sopsSet "$keysYaml" "[\"revoked\"][\"${keyName}@${slot}\"]" "$value" || return 1
    sops unset --input-type yaml --output-type yaml "$keysYaml" "[\"keys\"][\"${keyName}\"][\"slots\"][\"${slot}\"]" 2>/dev/null ||
      reconcile::fail "sops unset failed on ${keyName}@${slot}" || return 1
    K="$keyName" S="$slot" V="$value" yq -i '.revoked[strenv(K) + "@" + strenv(S)] = (strenv(V) | from_json) | del(.keys[strenv(K)].slots[strenv(S)])' "$work/expected.yaml"
  done
  for k in "${certs[@]}"; do
    local kk="${k%@*}" ss="${k#*@}" auth
    auth=$(K="$kk" S="$ss" yq -r '.keys[strenv(K)].slots[strenv(S)].certificates | keys | .[0]' "$keysYaml")
    cert=$(K="$kk" S="$ss" A="$auth" yq -r '.keys[strenv(K)].slots[strenv(S)].certificates[strenv(A)]["ssh-host"]' "$keysYaml")
    id=$(ssh-keygen -L -f <(printf '%s\n' "$cert") | awk '/^ *Key ID:/ { sub(/^ *Key ID: "/, ""); sub(/"$/, ""); print }')
    serial=$(ssh-keygen -L -f <(printf '%s\n' "$cert") | awk '/^ *Serial:/ { print $2 }')
    [[ -n $id && $serial =~ ^[0-9]+$ ]] || reconcile::fail "${k}: its host certificate has no key id or serial" || return 1
    value=$(A="$auth" S="$ss" I="$id" N="$serial" V="$revision" R="every principal's machine serves its own key (keys-reconcile retire ${machine})" \
      yq -n -o json -I0 '{"authority": strenv(A), "authority_slot": strenv(S), "key_id": strenv(I), "serial": (strenv(N) | tonumber), "revision": strenv(V), "reason": strenv(R)}')
    reconcile::sopsSet "$keysYaml" "[\"revoked_certificates\"][\"${k}/${serial}\"]" "$value" || return 1
    sops unset --input-type yaml --output-type yaml "$keysYaml" "[\"keys\"][\"${kk}\"][\"slots\"][\"${ss}\"][\"certificates\"][\"${auth}\"][\"ssh-host\"]" 2>/dev/null ||
      reconcile::fail "sops unset failed on ${k}'s host certificate" || return 1
    K="$kk" S="$ss" A="$auth" N="$k/$serial" V="$value" \
      yq -i '.revoked_certificates[strenv(N)] = (strenv(V) | from_json) | del(.keys[strenv(K)].slots[strenv(S)].certificates[strenv(A)]["ssh-host"])' "$work/expected.yaml"
  done

  : "postconditions: exactly these slots and certificates gone and their revocations added, no encrypted value moved"
  : "but the MAC, no private in clear"
  [[ "$(yq -o json -I0 'del(.sops)' "$keysYaml")" == "$(yq -o json -I0 'del(.sops)' "$work/expected.yaml")" ]] ||
    reconcile::fail "keys.yaml changed more than the retired slots and certificates" || return 1
  reconcile::tree::check || return 1
  "$keysJsonTool" "$keysYaml" || reconcile::fail "keys.json could not be regenerated" || return 1
  printf '%s\n' modules/home-manager/ssh.d/keys.yaml modules/home-manager/ssh.d/keys.json >>"$work/staged"
  {
    printf 'keys-reconcile retire: %s, at %s\n\n' "$machine" "${revision:0:12}"
    for slot in $retiredSlots; do printf 'revoked %s@%s (slot deleted)\n' "$keyName" "$slot"; done
    for k in "${certs[@]}"; do printf 'revoked_certificates %s (its host certificate removed)\n' "$k"; done
  } >"$work/summary"
  reconcile::tree::commit
}
