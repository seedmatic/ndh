# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles cache tokens, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles cache tokens" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
export NDH_LOGGER_XTRACE=0 # ndh::logger:command:run traces its command unless this is 0
unset BASH_XTRACEFD 2>/dev/null || true
unset BASH_ENV # a caller's BASH_ENV holding `set -x` would trace every child bash this script starts

# attic-token-mint — in the cache container, at every timer tick and by hand (« mint now »): mint this cache's tokens
# for every target machine, each ENCRYPTED to its access point's age recipient, into <out>/<dir>/ (dir: a hash of the
# machine and its public, naming no machine), where nginx serves them for the machine to pull:
# `netrc.<metalspace>.age` (a `machine` + `password` netrc fragment, every machine) and `write.token.age` (this
# metalspace's machines only). Each token is valid VALIDITY (twice the mint period): a missed tick is harmless, two
# fail closed. attic cannot revoke a token (its validation is stateless), so a compromise is cut by rotating the
# token-signing secret, which ends every token at once, then a mint now.
#
# A token exists in clear only inside one pipe: atticadm into age. It is never held in a variable, never an argument,
# never a file in clear. Each target's files are written beside, then renamed into place together.
#
# Env, fixed at eval: CACHE_FQDN, METALSPACE, CACHE_NAME, VALIDITY, TARGETS (one line per machine:
# `<machine> <metalspace> <dir> <ssh public key, type and base64>`).
# Usage: attic-token-mint <out dir>
out="${1:?usage: attic-token-mint <out dir>}"

log() { printf '[attic-token-mint] %s\n' "$*" >&2; }
die() {
  printf '[attic-token-mint] ERROR: %s\n' "$*" >&2
  exit 1
}
mint() { # <sub> <scope flags>... — the token on stdout, straight into the next pipe stage
  local sub="$1"
  shift
  atticd-atticadm make-token --sub "$sub" --validity "$VALIDITY" "$@" </dev/null
}

[ -n "$TARGETS" ] || die "no machine to mint for (no host-<seat> key recorded with a current slot)"
umask 022
mkdir -p "$out"
# A failed mint leaves no partial ciphertext behind; the previous generation stays served.
trap 'find "$out" -name "*.age.new" -delete 2>/dev/null' EXIT

minted=0
while read -r machine machineMetalspace dir keyType keyBase64; do
  [ -n "$machine" ] || continue
  [[ $dir =~ ^[0-9a-f]{64}$ ]] || die "the served directory of ${machine} is not a sha256: ${dir}"
  recipient="$(printf '%s %s\n' "$keyType" "$keyBase64" | ssh-to-age)" ||
    die "cannot derive an age recipient for ${machine} from its access point's host key"
  [[ $recipient == age1* ]] || die "the recipient derived for ${machine} is not an age key"
  mkdir -p "$out/$dir"

  # Every machine reads every cache: its netrc fragment for THIS cache.
  { printf 'machine %s\npassword ' "$CACHE_FQDN" && mint "$machine" --pull "$CACHE_NAME"; } |
    age -r "$recipient" -o "$out/$dir/netrc.$METALSPACE.age.new" ||
    die "minting ${machine}'s read token failed — its served tokens are left as they were"
  # Only this metalspace's own machines write into this cache.
  if [ "$machineMetalspace" = "$METALSPACE" ]; then
    mint "$machine" --push "$CACHE_NAME" --pull "$CACHE_NAME" |
      age -r "$recipient" -o "$out/$dir/write.token.age.new" ||
      die "minting ${machine}'s write token failed — its served tokens are left as they were"
  fi
  for f in "$out/$dir"/*.age.new; do
    chmod 0644 "$f"
    mv -f "$f" "${f%.new}"
    minted=$((minted + 1))
  done
  log "${machine}: minted for ${recipient}"
done <<<"$TARGETS"

log "done: ${minted} ciphertext file(s) under ${out}, valid ${VALIDITY}, nothing in clear"
