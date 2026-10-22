#!/usr/bin/env -S bash -euo pipefail
# @codebase
# keys-reconcile — the window step of the fabric-delivery frame (roles × keys K4, design §(k)): turn the publics the
# batch's machines generated (K3) into the fleet's trust, from the declaration alone.
#
#   keys-reconcile plan    reads no secret: collects each pending slot's publication over the seat's certified ssh,
#                          verifies it (F1, F2) and prints what the window would write. A session may run it.
#   keys-reconcile window  (armed through ndh-ops) measures the same way, shows it, asks ONE « oui » on the terminal,
#                          re-verifies that very measure and writes it into a clean worktree at the revision
#                          (write.sh): one local commit, never pushed. The measure lives in this process only.
#
# No other argument, by design (F5): the revision is the one this closure was built from, baked below, and it must be
# pushed; the batch is that revision's pending slots, in fleet-switch's order. A session can start it, never steer it.
# Prints names, slots, fingerprints and publics only.
source @nixBashTrampoline@
PATH="@toolPath@:/usr/bin:/bin"
export LC_ALL=C

readonly revision=@revision@ remote=@remote@ batch=@batch@ machines=@machines@ keysJson=@keysJson@ publishDir=@publishDir@
readonly delegation=@delegation@ keysJsonTool=@keysJsonTool@
# The bare plan and the window fetch the remote into, and the window adds its worktree to: never a session's checkout.
readonly bare="${XDG_CACHE_HOME:-$HOME/.cache}/keys-reconcile/ndh.git"
readonly ttyIn=@ttyIn@ ttyOut=@ttyOut@
source @verify@
source @write@

die() {
  printf '[keys-reconcile] refused: %s\n' "$*" >&2
  exit 3
}

armed() {
  : "F3: an unexpired delegation the operator armed, naming keys-reconcile (ndh-ops's file, root's own)"
  local expires
  [[ -f $delegation && ! -L $delegation ]] || return 1
  [[ "$(stat -c %u "$delegation" 2>/dev/null || stat -f %u "$delegation")" == 0 ]] || return 1
  expires=$(sed -n 's/^expires=//p' "$delegation")
  [[ $expires =~ ^[0-9]+$ ]] && (($(date +%s) < expires)) || return 1
  [[ ",$(sed -n 's/^tools=//p' "$delegation")," == *",keys-reconcile,"* ]]
}

pushed() {
  : "F5: the revision this closure was built from must be on ${remote}'s develop or main"
  local cache="$bare" branch
  [[ $revision =~ ^[0-9a-f]{40}$ ]] || die "this closure was built from no revision (${revision:-none}): switch the seat to a pushed revision first"
  [[ -d $cache ]] || git init -q --bare "$cache"
  git -C "$cache" fetch -q "$remote" +refs/heads/develop:refs/heads/develop +refs/heads/main:refs/heads/main ||
    die "cannot fetch develop and main from ${remote}"
  for branch in develop main; do
    git -C "$cache" merge-base --is-ancestor "$revision" "refs/heads/$branch" 2>/dev/null && return 0
  done
  die "${revision} is not pushed to ${remote} (develop or main): switch the seat to a pushed revision first"
}

collect() { # <machine> <key> <slot> <into dir>: the three published files, read over the machine's certified ssh
  local machine="$1" keyName="$2" slot="$3" into="$4" entry name f
  entry=$(m=$machine yq -e -o=json -I=0 '.[] | select(.name == strenv(m))' "$machines") || die "${machine} is not in the machine list"
  name=$(yq -r .ssh <<<"$entry")
  local -a opts
  mapfile -t opts < <(yq -r '.ssh_opts[]' <<<"$entry")
  for f in public statement statement.sig; do
    local src="${publishDir}/${keyName}@${slot}.${f}"
    if [[ -z $name ]]; then
      [[ -f $src ]] && cp "$src" "${into}/${keyName}@${slot}.${f}"
    else
      ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "${opts[@]}" "$name" "cat '$src'" \
        >"${into}/${keyName}@${slot}.${f}" 2>/dev/null || rm -f "${into}/${keyName}@${slot}.${f}"
    fi
  done
}

measure() { # <work dir>: collect and verify every slot of the batch into <work>; prints the plan, returns 4 if any is not ready
  local work="$1" n known ok=0 bad=0 i machine keyName slot oldPublic public files
  n=$(yq -p json -o json 'length' "$batch")
  known=$(yq -r -p json -o json '[(.keys, .authorities)[].slots[].public, (.revoked // {})[].public] | .[] | select(. != null)' "$keysJson")
  echo "plan de ${revision:0:12}, ${n} clé(s), dans l'ordre de fleet-switch :"
  : >"$work/measured"
  for ((i = 0; i < n; i++)); do
    machine=$(yq -r -p json -o json ".[$i].machine" "$batch")
    keyName=$(yq -r -p json -o json ".[$i].key" "$batch")
    slot=$(yq -r -p json -o json ".[$i].slot" "$batch")
    oldPublic=$(yq -r -p json -o json ".[$i].oldPublic" "$batch")
    files=$(yq -r -p json -o json ".[$i].files | join(\", \")" "$batch")
    collect "$machine" "$keyName" "$slot" "$work"
    if public=$(reconcile::verify "$work" "$keyName" "$slot" "$oldPublic" "$known" 2>"$work/why"); then
      printf '  ✓ %s — %s@%s %s\n' "$machine" "$keyName" "$slot" "$(ssh-keygen -lf <(printf '%s\n' "$public") | cut -d' ' -f2)"
      printf '      certificat ssh-host à signer ; destinataire %s ajouté à : %s\n' \
        "$(printf '%s\n' "$public" | ssh-to-age)" "$files"
      known+=$'\n'"${public#ssh-ed25519 }"
      printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$keyName" "$slot" "$public" \
        "$(cat "$work/${keyName}@${slot}".{public,statement,statement.sig} | sha256sum | cut -d' ' -f1)" >>"$work/measured"
      ok=$((ok + 1))
    else
      printf '  ✗ %s — %s@%s : %s\n' "$machine" "$keyName" "$slot" "$(sed 's/^\[keys-reconcile\] refused: //' "$work/why")"
      bad=$((bad + 1))
    fi
  done
  if ((bad > 0)); then
    echo "refusé : ${bad} clé(s) sur ${n} ne sont pas prêtes ; rien ne sera écrit."
    return 4
  fi
}

batch_empty() {
  [[ $(yq -p json -o json 'length' "$batch") == 0 ]] || return 1
  echo "rien à faire : aucune clé en attente dans la déclaration de ${revision:0:12}"
}

plan() {
  : "read-only: collect, verify, print; nothing is written but the fetch cache"
  batch_empty && return 0
  pushed
  local work rc=0
  work=$(mktemp -d)
  measure "$work" || rc=$?
  rm -rf "$work"
  ((rc == 0)) || return "$rc"
  echo "prêt : la fenêtre (ops next) les enregistrera, à la révision ${revision:0:12}."
}

window() {
  : "the window: measure, show, ONE « oui », re-verify the same measure, then write it into a clean worktree"
  armed || die "the window is not armed: ndh-ops arm --tools keys-reconcile (the operator's gesture)"
  batch_empty && return 0
  pushed
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  measure "$work" || return $?
  : "the « oui » is the operator's, on the terminal: the logger owns stdin's neighbours (fd 2 and 3), not the tty"
  local answer
  printf 'enregistrer, signer et re-chiffrer ces %s clé(s) à la révision %s ? [oui/non] ' "$(wc -l <"$work/measured")" "${revision:0:12}" >"$ttyOut"
  read -r answer <"$ttyIn" || answer=""
  [[ $answer == oui ]] || { echo "rien écrit : la réponse n'est pas « oui »"; return 5; }

  : "the same measure, re-collected and re-verified seconds later: a publication changed since is refused"
  local again i keyName slot public hash machine
  again=$(mktemp -d "$work/again.XXXXXX")
  while IFS=$'\t' read -r i keyName slot public hash; do
    machine=$(yq -r -p json -o json ".[$i].machine" "$batch")
    collect "$machine" "$keyName" "$slot" "$again"
    [[ "$(cat "$again/${keyName}@${slot}".{public,statement,statement.sig} 2>/dev/null | sha256sum | cut -d' ' -f1)" == "$hash" ]] ||
      die "${keyName}@${slot}: its publication changed since it was measured: nothing written"
  done <"$work/measured"
  reconcile::write "$work"
}

main() {
  (($# == 1)) || die "usage: keys-reconcile plan|window (no other argument: the revision and the batch are this closure's)"
  case $1 in
    plan) plan ;;
    window) window ;;
    *) die "usage: keys-reconcile plan|window" ;;
  esac
}

ndh::logger:command:run keys-reconcile main "$@"
