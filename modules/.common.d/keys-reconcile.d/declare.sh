# keys-reconcile declare <machine> (roles × keys, design §p): declare a machine's next host key — a pending slot, born
# on it — without a session's `sops set`. Sourced by keys-reconcile.sh; armed (F3), its « yes » on the tty.
#
# Its one argument is a MACHINE NAME, checked against the frozen machine list; everything else is derived from the
# revision's keys.yaml: the slot is today's date and must sort after every slot the key has; `origin: host`;
# `bootstrap: console` (the operator's witness: their eyes at its console, or their tailnet node list) exactly when the
# machine serves no key of its own (its current host slot is not `serving`, as
# for a machine on the shared rdp-host). Refused while a rotation is in flight: a slot `pending`, or `recorded` with
# `origin: host` (a born key not yet served). A `recorded, origin: keyring` slot does not block: it is the pushed key
# this rotation retires. Written in the window's worktree discipline (reconcile::tree::open/check/commit).

reconcile::declare() { # <machine>
  local machine="$1" keyName slots current state slot today field
  [[ $machine =~ ^[a-z][a-z0-9-]*$ ]] || die "declare: '${machine}' is not a machine name"
  m=$machine yq -e '.[] | select(.name == strenv(m))' "$machines" >/dev/null 2>&1 ||
    die "declare: ${machine} is not in the machine list"
  keyName="host-${machine}"
  K="$keyName" yq -e -p json '.keys | has(strenv(K))' "$keysJson" >/dev/null 2>&1 ||
    die "declare: keys.yaml has no ${keyName} entry"

  : "one rotation in flight at a time: a pending slot, or a born key recorded but not yet served, refuses"
  if [[ -n $(K="$keyName" yq -r -p json '.keys[strenv(K)].slots | to_entries[] | select(.value.state == "pending" or (.value.state == "recorded" and .value.origin == "host")) | .key' "$keysJson") ]]; then
    die "declare: ${keyName} has a rotation in flight (a pending slot, or a born key not yet served): finish it first"
  fi

  : "the slot is today's date, after every slot the key has"
  today=$(date -u +%y-%m-%d)
  slots=$(K="$keyName" yq -r -p json '.keys[strenv(K)].slots | keys | .[]' "$keysJson" | sort)
  local newest
  newest=$(tail -n1 <<<"$slots")
  [[ -z $newest || $newest < $today ]] ||
    die "declare: ${keyName}@${today} would not sort after its newest slot ${newest}: declare it another day"

  : "the exception is derived, never chosen: a console bootstrap exactly when no key of its own is served"
  current=$(K="$keyName" yq -r -p json '.keys[strenv(K)].slots | to_entries | map(select(.value.state != "pending" and .value.state != "retired")) | sort_by(.key) | .[-1].value.state // ""' "$keysJson")
  local -a fields=("state=pending" "origin=host")
  [[ $current == serving ]] || fields+=("bootstrap=console")

  : "refused BEFORE the operator is asked: a window of this revision still open would only refuse after their « yes »"
  reconcile::tree::free || return 1
  echo "declare ${keyName}@${today} in keys.yaml (revision ${revision:0:12}), the fields:"
  for field in "${fields[@]}"; do printf '  %s.slots."%s".%s = %s\n' "$keyName" "$today" "${field%%=*}" "${field#*=}"; done
  [[ $current == serving ]] ||
    echo "  ${machine} serves no key of its own: its first born key will be bound by your witness, its console or your tailnet's node list."
  local answer
  printf 'declare these fields? [yes/no] ' >>"$ttyOut"
  exec 7<"$ttyIn"
  read -r answer <&7 || answer=""
  exec 7<&-
  [[ $answer == yes ]] || { echo "nothing written: the answer is not « yes »"; return 5; }

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  reconcile::tree::open || return 1
  local keysYaml="$tree/modules/home-manager/ssh.d/keys.yaml" value
  cp "$keysYaml" "$work/expected.yaml"
  for field in "${fields[@]}"; do
    value=$(V="${field#*=}" yq -n -o json 'strenv(V)')
    reconcile::sopsSet "$keysYaml" "[\"keys\"][\"${keyName}\"][\"slots\"][\"${today}\"][\"${field%%=*}\"]" "$value" || return 1
    K="$keyName" S="$today" F="${field%%=*}" V="${field#*=}" yq -i '.keys[strenv(K)].slots[strenv(S)][strenv(F)] = strenv(V)' "$work/expected.yaml"
  done

  : "postconditions: exactly these fields added, no encrypted value moved but the MAC, no private in clear"
  [[ "$(yq 'del(.sops)' "$keysYaml")" == "$(yq 'del(.sops)' "$work/expected.yaml")" ]] ||
    reconcile::fail "keys.yaml changed more than the declared slot" || return 1
  reconcile::tree::check || return 1
  "$keysJsonTool" "$keysYaml" || reconcile::fail "keys.json could not be regenerated" || return 1
  printf '%s\n' modules/home-manager/ssh.d/keys.yaml modules/home-manager/ssh.d/keys.json >>"$work/staged"
  {
    printf 'keys-reconcile declare: %s@%s, pending, born on %s, at %s\n\n' "$keyName" "$today" "$machine" "${revision:0:12}"
    for field in "${fields[@]}"; do printf '%s.slots."%s".%s = %s\n' "$keyName" "$today" "${field%%=*}" "${field#*=}"; done
  } >"$work/summary"
  reconcile::tree::commit
}
