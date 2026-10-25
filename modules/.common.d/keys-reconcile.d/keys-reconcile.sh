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
#   keys-reconcile declare <machine>
#                          (armed) declares that machine's next host key, a pending slot born on it, in the same
#                          worktree discipline (declare.sh), after its « oui »: no session's sops set (design §p).
#   keys-reconcile close <rev12>
#                          (armed) removes one window left open, unmerged: its worktree and its branch, after checking
#                          it is a keys-reconcile window, clean and unpushed. The only way to discard one (write.sh).
#
# No other argument, by design (F5): the revision is the one this closure was built from, baked below, and it must be
# pushed; the batch is that revision's pending slots, in fleet-switch's order; declare's one argument is a machine
# name, checked against the frozen machine list. A session can start it, never steer it.
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
source @declare@
source @close@
source @classes@/attic-cache-key.sh
source @classes@/attic-tls-csr.sh

# A refusal goes to the operator's terminal as well: the logger sends stderr to the unified log, where nobody reads it.
say_refused() { # <message>
  printf '[keys-reconcile] refused: %s\n' "$1" >&2
  { printf 'refusé : %s\n' "$1" >>"$ttyOut"; } 2>/dev/null || true
}

die() {
  say_refused "$*"
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

fetch() { # <machine> <published dir> <into dir> <file>...: files a machine published, read over its certified ssh
  local machine="$1" from="$2" into="$3" entry name f
  shift 3
  entry=$(m=$machine yq -e -o=json -I=0 '.[] | select(.name == strenv(m))' "$machines") || die "${machine} is not in the machine list"
  name=$(yq -r .ssh <<<"$entry")
  local -a opts
  mapfile -t opts < <(yq -r '.ssh_opts[]' <<<"$entry")
  for f in "$@"; do
    local src="${from}/${f}"
    if [[ -z $name ]]; then
      [[ -f $src ]] && cp "$src" "${into}/${f}"
    else
      ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "${opts[@]}" "$name" "cat '$src'" \
        >"${into}/${f}" 2>/dev/null || rm -f "${into}/${f}"
    fi
  done
}

# An artifact class is a row of functions, reconcile::<class>::{measure,recheck,write,check}. The class names one only if it
# comes from the batch frozen at evaluation and names a row this tool defines: no string a machine published ever
# reaches a function name.
class_of() { # <batch index> → its class, or fails
  local class f
  class=$(yq -r -p json -o json ".[$1].class" "$batch")
  [[ $class =~ ^[a-z][a-z0-9-]*$ ]] || return 1
  for f in measure recheck write check; do declare -F "reconcile::${class}::${f}" >/dev/null || return 1; done
  printf '%s\n' "$class"
}

: "row one, the host key (K4): a pending slot's public, its F1 statement and signature"
# The files a slot publishes: its public, and its F1 statement and signature unless it is a bootstrap (§o): a machine
# that serves no key of its own publishes its public alone, and its binding is the operator's witness layer.
reconcile::host-key::files() { # <batch index> → one file name per line
  local keyName slot
  keyName=$(yq -r -p json -o json ".[$1].key" "$batch")
  slot=$(yq -r -p json -o json ".[$1].slot" "$batch")
  if [[ $(yq -r -p json -o json ".[$1].bootstrap // \"\"" "$batch") =~ ^(console|tailnet)$ ]]; then
    printf '%s\n' "${keyName}@${slot}.public"
  else
    printf '%s\n' "${keyName}@${slot}".{public,statement,statement.sig}
  fi
}

reconcile::host-key::collect() { # <batch index> <into dir>
  local -a files
  mapfile -t files < <(reconcile::host-key::files "$1")
  fetch "$(yq -r -p json -o json ".[$1].machine" "$batch")" "$publishDir" "$2" "${files[@]}"
}

reconcile::host-key::hash() { # <batch index> <dir>: the sha256 of the slot's published files, in order
  local f
  while IFS= read -r f; do cat "$2/$f" 2>/dev/null; done < <(reconcile::host-key::files "$1") | sha256sum | cut -d' ' -f1
}

reconcile::host-key::measure() { # <batch index> <work dir>: collect and verify one slot, print its plan lines, record it
  local i="$1" work="$2" machine keyName slot oldPublic public files bootstrap
  machine=$(yq -r -p json -o json ".[$i].machine" "$batch")
  bootstrap=$(yq -r -p json -o json ".[$i].bootstrap // \"\"" "$batch")
  keyName=$(yq -r -p json -o json ".[$i].key" "$batch")
  slot=$(yq -r -p json -o json ".[$i].slot" "$batch")
  oldPublic=$(yq -r -p json -o json ".[$i].oldPublic" "$batch")
  files=$(yq -r -p json -o json ".[$i].files | join(\", \")" "$batch")
  reconcile::host-key::collect "$i" "$work"
  : >"$work/why"
  if public=$(NDH_RECONCILE_WHY="$work/why" reconcile::host-key::verify "$work" "$keyName" "$slot" "$oldPublic" "$known" "$bootstrap"); then
    printf '  ✓ %s — %s@%s %s\n' "$machine" "$keyName" "$slot" "$(ssh-keygen -lf <(printf '%s\n' "$public") | cut -d' ' -f2)"
    : "a bootstrap's binding is the operator's witness layer, outside this tool: each layer trusts the one below it"
    case $bootstrap in
      console) printf '      témoin : toi, à la console de %s, ou la liste des nœuds de ton tailnet\n' "$machine" ;;
      tailnet) printf '      témoin : la liste des nœuds de ton tailnet (%s y est seul sous son nom)\n' "$machine" ;;
    esac
    printf '      certificat ssh-host à signer ; destinataire %s ajouté à : %s\n' \
      "$(printf '%s\n' "$public" | ssh-to-age)" "$files"
    known+=$'\n'"${public#ssh-ed25519 }"
    printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$keyName" "$slot" "$public" "$(reconcile::host-key::hash "$i" "$work")" >>"$work/measured"
  else
    printf '  ✗ %s — %s@%s : %s\n' "$machine" "$keyName" "$slot" "$(sed 's/^\[keys-reconcile\] refused: //' "$work/why")"
    return 1
  fi
}

reconcile::host-key::recheck() { # <work dir> <again dir>: the measured slots, re-collected: a publication changed since is refused
  local i keyName slot public hash
  while IFS=$'\t' read -r i keyName slot public hash; do
    reconcile::host-key::collect "$i" "$2"
    [[ "$(reconcile::host-key::hash "$i" "$2")" == "$hash" ]] ||
      die "${keyName}@${slot}: its publication changed since it was measured: nothing written"
  done <"$1/measured"
}

measure() { # <work dir>: collect and verify every entry of the batch into <work>; prints the plan, returns 4 if any is not ready
  local work="$1" n bad=0 i class
  n=$(yq -p json -o json 'length' "$batch")
  known=$(yq -r -p json -o json '[(.keys, .authorities)[].slots[].public, (.revoked // {})[].public] | .[] | select(. != null)' "$keysJson")
  present=()
  echo "plan de ${revision:0:12}, ${n} clé(s), dans l'ordre de fleet-switch :"
  : >"$work/measured"
  for ((i = 0; i < n; i++)); do
    class=$(class_of "$i") || die "batch entry ${i}: no artifact class '$(yq -r -p json -o json ".[$i].class" "$batch")' in keys-reconcile"
    [[ " ${present[*]} " == *" ${class} "* ]] || present+=("$class")
    "reconcile::${class}::measure" "$i" "$work" || bad=$((bad + 1))
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
  : "refused BEFORE the operator is asked anything: a window already open would only refuse after their answers"
  reconcile::tree::free || return 1
  : "the operator's terminal, opened once for every answer of this window"
  exec 7<"$ttyIn"
  local answer
  : "the « oui » is the operator's, on the terminal: the logger owns stdin's neighbours (fd 2 and 3), not the tty"
  printf 'enregistrer, signer et re-chiffrer ces %s clé(s) à la révision %s ? [oui/non] ' "$(cat "$work/measured" "$work"/*.measured 2>/dev/null | wc -l)" "${revision:0:12}" >>"$ttyOut"
  read -r answer <&7 || answer=""
  exec 7<&-
  [[ $answer == oui ]] || { echo "rien écrit : la réponse n'est pas « oui »"; return 5; }

  : "the same measure, re-collected and re-verified seconds later: a publication changed since is refused"
  local again class
  again=$(mktemp -d "$work/again.XXXXXX")
  for class in "${present[@]}"; do "reconcile::${class}::recheck" "$work" "$again"; done
  : "one worktree; every class writes into it; then EVERY class's postconditions, so a later class cannot spoil an"
  : "earlier one's file; one commit"
  reconcile::tree::open || return 1
  for class in "${present[@]}"; do "reconcile::${class}::write" "$work" || return 1; done
  for class in "${present[@]}"; do "reconcile::${class}::check" "$work" || return 1; done
  reconcile::tree::check || return 1
  reconcile::tree::commit
}

main() {
  : "F5: plan and window take no argument; declare takes one, a machine name, checked against the frozen list"
  case "${1:-}:$#" in
    plan:1) plan ;;
    window:1) window ;;
    declare:2)
      armed || die "declare is not armed: ndh-ops arm --tools keys-reconcile (the operator's gesture)"
      pushed
      reconcile::declare "$2"
      ;;
    close:2)
      armed || die "close is not armed: ndh-ops arm --tools keys-reconcile (the operator's gesture)"
      reconcile::close "$2"
      ;;
    *) die "usage: keys-reconcile plan | window | declare <machine> | close <rev12> (no other argument: the revision is this closure's)" ;;
  esac
}

ndh::logger:command:run keys-reconcile main "$@"
