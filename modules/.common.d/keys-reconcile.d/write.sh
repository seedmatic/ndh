# keys-reconcile's write (roles × keys K4, design §k2), sourced by keys-reconcile.sh and run only by its window, after
# the « oui » and the re-verification of the measure. It writes into a clean worktree of the bare at the revision,
# never into a checkout a session works in, and commits there once; it pushes nothing.
#
#   reconcile::host-key::write <work>   <work>/measured: one line per slot, `<batch index>\t<key>\t<slot>\t<public>\t<hash>`
#
# Per slot: the public, its age, `recipient: true`, `state: recorded` and its ssh-host certificate, each by `sops set`
# on keys.yaml; each new age into every rule of .sops.yaml; then `sops updatekeys` of every file those rules govern;
# keys.json regenerated. The authority's signing slot is decrypted ONCE, into a private ssh-agent, in a secret window
# (ndh::secret:begin/end), never into a variable or a file; sops' stderr is never shown (it can quote plaintext).
#
# Refused, nothing committed, unless after the writes: keys.yaml without its sops metadata is the input plus exactly
# the fields set here; every ENC[…] value of every file touched that was not set here is byte-identical to the
# revision's (only the MAC, lastmodified and recipient stanzas may move: a whole-file re-encryption is refused); every
# private is still ENC[…].

reconcile::fail() {
  printf '[keys-reconcile] refused: %s; nothing committed (the worktree %s is left for reading)\n' "$1" "${tree:-?}" >&2
  return 1
}

# Every ENC[…] value of a sops file, with its path, the sops metadata aside: what a re-encryption would rewrite.
reconcile::encrypted() { # <file>
  yq -r 'del(.sops) | .. | select(tag == "!!str" and test("^ENC\[")) | (path | map(tostring) | join(".")) + "\t" + .' "$1" | sort
}

reconcile::sopsSet() { # <file> <path as a yq-style list of keys> <JSON value>
  local err rc=0
  err=$(mktemp)
  sops set --input-type yaml --output-type yaml "$1" "$2" "$3" 2>"$err" || rc=$?
  rm -f "$err"
  ((rc == 0)) || reconcile::fail "sops set failed (exit ${rc}) on ${1##*/} at ${2}"
}

# The sops files whose every rule carries a host recipient: the encrypted values the window must leave byte-identical.
sopsFiles=(.secrets catalog/cache-trust.yaml modules/home-manager/ssh.d/keys.yaml)

# reconcile::tree::open: the window's one clean worktree of the bare at the revision, on its own local branch; every
# class writes into it, and reconcile::tree::commit commits it once. The encrypted values are snapshotted here, before
# ANY class writes, so the byte-identity postcondition covers every class's writes, not only the host keys'.
reconcile::tree::open() {
  local f
  branch="keys-reconcile/${revision:0:12}"
  tree="${XDG_STATE_HOME:-$HOME/.local/state}/keys-reconcile/${revision:0:12}"
  [[ ! -e $tree ]] || reconcile::fail "${tree} already exists: a previous window was not closed (read it, then remove it)" || return 1
  git -C "$bare" cat-file -e "${revision}^{commit}" 2>/dev/null || reconcile::fail "${revision} is not in ${bare}" || return 1
  git -C "$bare" worktree add -q -b "$branch" "$tree" "$revision" || reconcile::fail "cannot add the worktree at ${revision}" || return 1
  for f in "${sopsFiles[@]}"; do reconcile::encrypted "$tree/$f" >"$work/before.${f//\//_}"; done
  : >"$work/staged"
  : >"$work/summary"
}

# reconcile::tree::check: after EVERY class wrote, before the commit: no encrypted value of any sops file moved (a
# whole-file re-encryption is refused, by whichever class), and no private is left in clear.
reconcile::tree::check() {
  local f
  for f in "${sopsFiles[@]}"; do
    reconcile::encrypted "$tree/$f" >"$work/after.${f//\//_}"
    [[ "$(cut -f2 "$work/before.${f//\//_}")" == "$(cut -f2 "$work/after.${f//\//_}")" ]] ||
      reconcile::fail "${f}: an encrypted value changed (a whole-file re-encryption?): only recipient stanzas may move" || return 1
  done
  [[ "$(yq '[.keys[].slots[].private, .authorities[].slots[].private] | map(select(. != null)) | all_c(test("^ENC\["))' "$tree/modules/home-manager/ssh.d/keys.yaml")" == true ]] ||
    reconcile::fail "a private is not encrypted in keys.yaml" || return 1
}

# reconcile::tree::commit: one local commit of what the classes staged (<work>/staged, one path per line), with each
# class's summary lines (<work>/summary) as its message; never pushed.
reconcile::tree::commit() {
  local -a paths
  mapfile -t paths < <(sort -u "$work/staged")
  git -C "$tree" add -- "${paths[@]}"
  git -C "$tree" commit -q -F "$work/summary" || reconcile::fail "the commit failed" || return 1
  echo "écrit dans ${tree}, branche ${branch} (locale, non poussée) : à relire puis à fusionner, avec ton feu vert."
}

reconcile::host-key::write() {
  local work="$1" i keyName slot public hash age entry authority authSlot serial principals certId cert value
  local keysYaml="$tree/modules/home-manager/ssh.d/keys.yaml" sopsYaml="$tree/.sops.yaml"
  local f
  cp "$keysYaml" "$work/expected.yaml"

  : "the ssh authority's signing slot: the oldest not compromised, as every trust store carries it"
  authority=$(yq -r '[.authorities | to_entries[] | select(.value.usage // [] | contains(["ssh-authority"])) | .key] | .[0]' "$keysYaml")
  authSlot=$(A="$authority" yq -r '.authorities[strenv(A)].slots | to_entries | map(select(.value.compromised // false | not)) | .[0].key' "$keysYaml")
  [[ -n $authority && $authority != null && -n $authSlot && $authSlot != null ]] || reconcile::fail "keys.yaml names no ssh-authority signing slot" || return 1
  printf '%s %s\n' "$(A="$authority" yq -r '.authorities[strenv(A)].type // "ssh-ed25519"' "$keysYaml")" \
    "$(A="$authority" S="$authSlot" yq -r '.authorities[strenv(A)].slots[strenv(S)].public' "$keysYaml")" >"$work/authority.pub"
  serial=$(($(yq -r '[(.keys // {})[] | (.slots // {})[] | (.certificates // {})[] | .[] | select(tag == "!!str")] | .[]' "$keysYaml" |
    while IFS= read -r c; do printf '%s\n' "$c" | ssh-keygen -L -f - | awk '/^ *Serial:/ { print $2 }'; done | sort -n | tail -1) + 1))

  : "the agent that signs; its key is loaded in a secret window and expires by itself (-t 120)"
  local sock="$work/agent.sock" agentPid
  agentPid=$(ssh-agent -s -a "$sock" | sed -n 's/^SSH_AGENT_PID=\([0-9]*\);.*/\1/p')
  [[ -n $agentPid ]] || reconcile::fail "cannot start the ssh-agent that signs" || return 1
  trap 'kill "$agentPid" 2>/dev/null; rm -rf "$work"' EXIT
  local -a rcs=(0 0)
  declare -F ndh::secret:begin >/dev/null && declare -F ndh::secret:end >/dev/null ||
    reconcile::fail "the trampoline has no ndh::secret window (fix/secret-xtrace-guard): nothing decrypted" || return 1
  ndh::secret:begin "the ssh authority's signing slot, from keys.yaml into this run's own agent"
  { sops --decrypt --extract "[\"authorities\"][\"${authority}\"][\"slots\"][\"${authSlot}\"][\"private\"]" "$keysYaml" 2>/dev/null && echo; } |
    SSH_AUTH_SOCK="$sock" ssh-add -t 120 -q - 2>/dev/null || rcs=("${PIPESTATUS[@]}")
  ndh::secret:end
  ((rcs[0] == 0)) || reconcile::fail "the authority's slot did not decrypt (the operator's sops identity)" || return 1
  ((rcs[1] == 0)) || reconcile::fail "the authority's slot did not load into the agent" || return 1

  while IFS=$'\t' read -r i keyName slot public hash; do
    : "${keyName}@${slot}: record the public and its age, sign its ssh-host certificate, mark it recorded"
    age=$(printf '%s\n' "$public" | ssh-to-age)
    principals=$(yq -r -p json -o json ".[$i].principals | join(\",\")" "$batch")
    certId=$(KEYNAME="$keyName" NAMES="$(printf '%s' "$principals" | sha256sum | cut -d' ' -f1)" ISSUED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      yq -n -o json -I 0 '{"marker": "ndh-ssh-key-meta-v1", "owner": "home-manager.ssh-add-keys", "key": strenv(KEYNAME), "usage": ["ssh-host"], "names": strenv(NAMES), "issued": strenv(ISSUED)}')
    printf '%s %s\n' "$public" "$keyName" >"$work/${keyName}.pub"
    SSH_AUTH_SOCK="$sock" ssh-keygen -q -U -s "$work/authority.pub" -I "$certId" -z "$serial" -n "$principals" -h "$work/${keyName}.pub" ||
      reconcile::fail "ssh-keygen could not sign ${keyName}@${slot}" || return 1
    [[ -s "$work/${keyName}-cert.pub" ]] || reconcile::fail "no certificate was written for ${keyName}@${slot}" || return 1
    cert=$(<"$work/${keyName}-cert.pub")
    serial=$((serial + 1))

    local base="[\"keys\"][\"${keyName}\"][\"slots\"][\"${slot}\"]"
    for entry in "public=${public#ssh-ed25519 }" "age=${age}" "state=recorded" "certificates.${authority}.ssh-host=${cert}"; do
      local field="${entry%%=*}" val="${entry#*=}" path="$base"
      IFS=. read -ra parts <<<"$field"
      for part in "${parts[@]}"; do path+="[\"${part}\"]"; done
      value=$(V="$val" yq -n -o json 'strenv(V)')
      reconcile::sopsSet "$keysYaml" "$path" "$value" || return 1
      P="$field" V="$val" K="$keyName" S="$slot" yq -i '.keys[strenv(K)].slots[strenv(S)] |= setpath(strenv(P) | split("."); strenv(V))' "$work/expected.yaml"
    done
    reconcile::sopsSet "$keysYaml" "${base}[\"recipient\"]" true || return 1
    K="$keyName" S="$slot" yq -i '.keys[strenv(K)].slots[strenv(S)].recipient = true' "$work/expected.yaml"

    : "${keyName}@${slot}: its age joins every rule of .sops.yaml"
    A="$age" yq -i '.creation_rules[].age += [strenv(A)]' "$sopsYaml"
    printf '      %s@%s enregistrée, certifiée (série %s), destinataire %s\n' "$keyName" "$slot" "$((serial - 1))" "$age"
  done <"$work/measured"
  kill "$agentPid" 2>/dev/null || true

  : "re-key every file the rules govern: recipient stanzas only"
  for f in "${sopsFiles[@]}"; do
    (cd "$tree" && sops updatekeys -y --input-type yaml "$f" >/dev/null 2>&1) || reconcile::fail "sops updatekeys failed on ${f}" || return 1
  done

  "$keysJsonTool" "$keysYaml" || reconcile::fail "keys.json could not be regenerated" || return 1
  printf '%s\n' .sops.yaml "${sopsFiles[@]}" modules/home-manager/ssh.d/keys.json >>"$work/staged"
  printf 'keys-reconcile: record %s host key(s) at %s\n\n%s\n' "$(wc -l <"$work/measured")" "${revision:0:12}" \
    "$(cut -f2,3 "$work/measured" | tr '\t' '@')" >>"$work/summary"
}

# The host keys' own postcondition, run by the window after every class wrote: keys.yaml is the input plus exactly the
# fields this window set (the encrypted values and the privates are reconcile::tree::check's, for every class).
reconcile::host-key::check() {
  [[ "$(yq 'del(.sops)' "$tree/modules/home-manager/ssh.d/keys.yaml")" == "$(yq 'del(.sops)' "$1/expected.yaml")" ]] ||
    reconcile::fail "keys.yaml changed more than the fields this window set" || return 1
}
