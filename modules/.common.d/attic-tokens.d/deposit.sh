# ndh-attic-tokens-deposit <dir> — the operator's gesture after attic-token-issue (roles × keys ⑤): gives each
# machine of the inventory its own attic tokens, as the ciphertext the issue wrote in <dir>/<machine>/. The
# frame carries age ciphertext only, sealed to its target, so it travels over the operator's fleet ssh
# (certs only) to each machine's receive, by its fixed path under sudo -n; the operator seat takes its own
# locally. A machine without a dir in <dir> is left as it is. Tokens have no lifetime: this repeats only
# after a token-signing secret's rotation, or for a new machine.
#
# Header, fixed at evaluation: seat, localSudo, localReceive, and per machine its kind and ssh name (targetKind,
# targetSsh), from the inventory and the operator's aliases.

log() { printf '[ndh-attic-tokens-deposit] %s\n' "$*" >&2; }
die() {
  printf '[ndh-attic-tokens-deposit] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 && -d $1 ]] || die "usage: ndh-attic-tokens-deposit <dir written by attic-token-issue>"
src=$1
shopt -s nullglob
# By name, in byte order: the glob's order follows the caller's collation.
mapfile -t machines < <(for d in "$src"/*/; do basename "$d"; done | LC_ALL=C sort)
for m in "${machines[@]}"; do
  [[ $m == "$seat" || -v "targetKind[$m]" ]] || die "${src}/${m}: not a machine of the inventory — nothing sent"
done

frame() { # <machine>
  local f
  printf 'ndh-attic-tokens/1 %s\n' "$1"
  for f in "$src/$1"/netrc.*.age "$src/$1"/write.token.age; do
    [[ -e $f ]] || continue
    printf 'item %s %s\n' "$(basename "$f")" "$(base64 <"$f" | tr -d '\n')"
  done
  printf 'end\n'
}

sent=() failed=()
for m in "${machines[@]}"; do
  if [[ $m == "$seat" ]]; then
    frame "$m" | "$localSudo" -n "$localReceive" && sent+=("$m") || failed+=("$m")
    continue
  fi
  case ${targetKind[$m]} in
    nixos) rsudo=/run/wrappers/bin/sudo ;;
    darwin) rsudo=/usr/bin/sudo ;;
  esac
  if frame "$m" | ssh -o BatchMode=yes -o ConnectTimeout=10 "${targetSsh[$m]}" \
    "$rsudo -n /run/current-system/sw/bin/ndh-attic-tokens-receive"; then
    sent+=("$m")
  else
    failed+=("$m")
  fi
done
log "deposited on: ${sent[*]:-none}"
((${#failed[@]} == 0)) || die "not deposited on: ${failed[*]} (their messages are above); the others are"
