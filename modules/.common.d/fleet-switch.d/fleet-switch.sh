# fleet-switch: switch the fleet to ONE pushed, merged revision of ndh, one machine at a time, through ndh-switch (the
# only per-machine switch; this loop never rebuilds nor reaches a machine itself). The machines and their order come
# from ndh-switch's machine list: the NixOS guests, then the remote darwin hosts, then the operator seat LAST, and
# the seat only when the operator named it in the go (--with-seat). Each machine must come back `reachable` before
# the next starts; the first failure stops the loop and prints the copy-exact recovery.
#
# The seat's activation may sign with the TLS authority (signers.yaml): before the seat, each signer its target
# config enables is asked `--check`, which classifies and never decrypts, but only on a revision that carries that
# signer's no-decrypt fix. Anything but "nothing due" stops before the seat: a signature is the operator's gesture.
#
# Every run, --dry-run included (it runs each signer's --check, code taken from the revision), runs only inside a window
# the operator armed (F3: `ndh-ops arm --tools fleet-switch`), checked HERE, as keys-reconcile checks its own: nobody is
# asked « oui », the arming is the go. The seat is the operator's own: --with-seat needs a second item,
# `fleet-switch-seat`, in the same arming.
#
# The revision must be merged before any of its code is evaluated or run: ndh-switch's own check, the layer below, is
# asked first (`ndh-switch --dry-run` on the plan's first machine, which evaluates and runs nothing).
set -euo pipefail

state="${XDG_CACHE_HOME:-$HOME/.cache}/fleet-switch/ndh.git"
dry=0 with_seat=0 only="" rev=""

die() {
  echo "fleet-switch: refused: $*" >&2
  exit 2
}

armed() { # <item>
  : "F3: an unexpired delegation the operator armed, naming <item> (ndh-ops's file, root's own), as keys-reconcile"
  local expires
  [[ -f $delegation && ! -L $delegation ]] || return 1
  [[ "$(stat -c %u "$delegation" 2>/dev/null || stat -f %u "$delegation")" == 0 ]] || return 1
  expires=$(sed -n 's/^expires=//p' "$delegation")
  [[ $expires =~ ^[0-9]+$ ]] && (($(date +%s) < expires)) || return 1
  [[ ",$(sed -n 's/^tools=//p' "$delegation")," == *",$1,"* ]]
}

usage() {
  echo "usage: fleet-switch [--dry-run] [--with-seat] [--only <machine>[,<machine>…]] [--rev <40-hex>]" >&2
  exit 2
}

while (($#)); do
  case $1 in
    --dry-run) dry=1 ;;
    --with-seat) with_seat=1 ;;
    --only) (($# >= 2)) || usage; only=$2; shift ;;
    --rev) (($# >= 2)) || usage; rev=$2; shift ;;
    *) usage ;;
  esac
  shift
done

armed fleet-switch || die "a switch of the fleet is not armed: ndh-ops arm --tools fleet-switch (the operator's gesture)"
((!with_seat)) || armed fleet-switch-seat ||
  die "the seat is not armed: ndh-ops arm --tools fleet-switch,fleet-switch-seat (the operator's gesture)"

yq -e '([.[] | select(.kind != "nixos" and .kind != "darwin")] | length) == 0 and
  ([.[] | select(.kind == "darwin" and .ssh == "")] | length) == 1' "$machines" >/dev/null ||
  die "the machine list: every machine nixos or darwin, and exactly one operator seat (ssh \"\")"
mapfile -t order < <(yq -r '([.[] | select(.kind == "nixos")] + [.[] | select(.kind == "darwin" and .ssh != "")]
  + [.[] | select(.kind == "darwin" and .ssh == "")]) | .[].name' "$machines")
seat=$(yq -r '.[] | select(.kind == "darwin" and .ssh == "") | .name' "$machines")

declare -A wanted=()
if [[ -n $only ]]; then
  IFS=, read -ra names <<<"$only"
  for n in "${names[@]}"; do
    known=0
    for m in "${order[@]}"; do
      if [[ $m == "$n" ]]; then known=1; fi
    done
    ((known)) || die "unknown machine: $n"
    wanted[$n]=1
  done
fi

if [[ -z $rev ]]; then
  rev=$(git ls-remote "$remote" refs/heads/develop | cut -f1) || die "cannot read develop's head from $remote"
fi
[[ $rev =~ ^[0-9a-f]{40}$ ]] || die "not a full revision: $rev"
flake="$flake_base/$rev"

results=()
plan=()
for m in "${order[@]}"; do
  if [[ -n $only && -z ${wanted[$m]:-} ]]; then
    results+=("$m: skipped (not in --only)")
  elif [[ $m == "$seat" ]] && ((!with_seat)); then
    results+=("$m: skipped (not named in the go)")
  else
    plan+=("$m")
    results+=("$m: pending")
  fi
done

result() { # $1 = machine, $2 = its line
  local i
  for i in "${!results[@]}"; do
    if [[ ${results[$i]} == "$1: "* ]]; then
      results[i]="$1: $2"
    fi
  done
}

finish() { # $1 = exit status
  local mode=""
  ((dry)) && mode=" (dry-run)"
  echo "== fleet-switch: rev ${rev:0:12}$mode"
  printf '%s\n' "${results[@]}"
  exit "$1"
}

stop_rest() { # $1 = the machine that stopped the loop
  local m
  for m in "${plan[@]}"; do
    case " ${done_list:-} $1 " in *" $m "*) ;; *) result "$m" "not run (stopped at $1)" ;; esac
  done
}

enabled_signers() { # $1 = darwin machine: the signers its TARGET config runs at activation
  local name option on
  while read -r name option; do
    on=$(nix eval --json "$flake#darwinConfigurations.$1.config.ndh.$option.atActivation") ||
      return 1
    if [[ $on == true ]]; then
      echo "$name"
    fi
  done < <(yq -r '.[] | .name + " " + .option' "$signers")
  return 0
}

guard_seat() { # the seat's activation must sign nothing: every enabled signer, on a no-decrypt revision, says 0
  local name fix rc
  local -a list
  mapfile -t list < <(enabled_signers "$seat" || echo "!")
  if [[ ${list[*]:-} == *"!"* ]]; then
    echo "cannot evaluate $seat's activation signers at ${rev:0:12}"
    return 1
  fi
  [[ -d $state ]] || git init -q --bare "$state"
  git -C "$state" fetch -q --filter=blob:none "$remote" +refs/heads/develop:refs/heads/develop ||
    { echo "cannot fetch develop from $remote"; return 1; }
  for name in "${list[@]}"; do
    fix=$(n=$name yq -r '.[] | select(.name == strenv(n)) | .noDecryptFix' "$signers")
    if ! git -C "$state" merge-base --is-ancestor "$fix" "$rev" 2>/dev/null; then
      echo "target rev predates $name's no-decrypt fix; the operator's gesture"
      return 1
    fi
    rc=0
    nix run "$flake#$name" -- --check >&2 || rc=$?
    case $rc in
      0) ;;
      10) echo "a signature is due ($name), the operator's gesture"; return 1 ;;
      *) echo "$name --check could not classify (exit $rc): not activating"; return 1 ;;
    esac
  done
  return 0
}

((${#plan[@]})) || finish 0
: "merged, before any of the revision's code is evaluated or run: ndh-switch's check, which a dry run evaluates nothing past"
"$ndh_switch" --dry-run "${plan[0]}" "$rev" >&2 || die "ndh-switch refused ${rev:0:12} (above): nothing evaluated, nothing switched"

for m in "${plan[@]}"; do
  if [[ $m != "$seat" ]] && [[ $(m=$m yq -r '.[] | select(.name == strenv(m)) | .kind' "$machines") == darwin ]]; then
    if ! remote_signers=$(enabled_signers "$m"); then
      result "$m" "STOPPED: cannot evaluate its activation signers"
      stop_rest "$m"
      finish 4
    fi
    if [[ -n $remote_signers ]]; then
      result "$m" "STOPPED: a remote darwin host whose activation signs ($remote_signers): only the seat may hold the authority"
      stop_rest "$m"
      finish 4
    fi
  fi
  if [[ $m == "$seat" ]] && ! why=$(guard_seat); then
    result "$m" "STOPPED: $why"
    stop_rest "$m"
    finish 4
  fi

  log=$(mktemp)
  rc=0
  if ((dry)); then
    "$ndh_switch" --dry-run "$m" "$rev" 2>&1 | tee "$log" || rc=$?
  else
    "$ndh_switch" "$m" "$rev" 2>&1 | tee "$log" || rc=$?
  fi
  previous=$(sed -nE 's/^previous: ([^ ]+) \(revision ([^)]*)\)$/\1/p' "$log" | tail -1)
  previous_rev=$(sed -nE 's/^previous: ([^ ]+) \(revision ([^)]*)\)$/\2/p' "$log" | tail -1)
  reached=$(sed -nE 's/^reachable: (.+)$/\1/p' "$log" | tail -1)
  rm -f "$log"
  done_list="${done_list:-} $m"

  if ((dry)) && ((rc == 0)); then
    result "$m" "would switch (dry-run)"
    continue
  fi
  if ((rc == 0)) && [[ -n $reached ]]; then
    result "$m" "switched $previous -> $reached (rev ${rev:0:12})"
    continue
  fi
  ((rc != 0)) || rc=1
  if [[ $previous_rev =~ ^[0-9a-f]{40}$ ]]; then
    recover="ndh-switch $m $previous_rev"
  elif [[ -n $previous ]]; then
    recover="by generation $previous"
  else
    recover="nothing to recover: ndh-switch stopped before switching"
  fi
  result "$m" "FAILED (exit $rc); recover: $recover"
  stop_rest "$m"
  finish "$rc"
done
finish 0
