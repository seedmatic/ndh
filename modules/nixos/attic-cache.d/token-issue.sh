# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
unset BASH_XTRACEFD 2>/dev/null || true

# attic-token-issue — mint this metalspace's cache tokens for every machine that reads it, and the
# write tokens of its own access point's machines, each ENCRYPTED to the target access point's age
# recipient, into <out>/<machine>/: `netrc.<metalspace>.age` (one `machine` + `password` netrc
# fragment) and, for this metalspace's machines, `write.token.age`. roles x keys' drop-box carries
# them; its delivery decrypts them into ndh.atticClient.paths.
#
# A token exists in clear only inside this pipe: minted in the cache container, piped into age on
# this NixOS guest. It is never held in a variable, never an argument, never a file in clear.
#
# Env, fixed at eval: CACHE_FQDN, METALSPACE, CACHE_NAME, PROJECT, INSTANCE, TARGETS (one line per
# machine: `<machine> <metalspace> <ssh public key, type and base64>`).
# Usage: attic-token-issue <out dir> <read validity> <write validity>
out="${1:?usage: attic-token-issue <out dir> <read validity> <write validity>}"
readValidity="${2:?usage: attic-token-issue <out dir> <read validity> <write validity>}"
writeValidity="${3:?usage: attic-token-issue <out dir> <read validity> <write validity>}"

log() { printf '[attic-token-issue] %s\n' "$*" >&2; }
die() {
  printf '[attic-token-issue] ERROR: %s\n' "$*" >&2
  exit 1
}
mint() { # <sub> <validity> <scope flags>... — the token on stdout, straight into the next pipe stage
  local sub="$1" validity="$2"
  shift 2
  incus --project "$PROJECT" exec --cwd / "$INSTANCE" -- \
    atticd-atticadm make-token --sub "$sub" --validity "$validity" "$@" </dev/null
}

[ -n "$TARGETS" ] || die "no machine to issue for (no host-<seat> key recorded for any access point)"
umask 077
mkdir -p "$out"
# A failed issue leaves no partial ciphertext behind.
trap 'find "$out" -name "*.age.tmp" -delete 2>/dev/null' EXIT

issued=0
while read -r machine machineMetalspace keyType keyBase64; do
  [ -n "$machine" ] || continue
  recipient="$(printf '%s %s\n' "$keyType" "$keyBase64" | ssh-to-age)" ||
    die "cannot derive an age recipient for ${machine} from its access point's host key"
  [[ $recipient == age1* ]] || die "the recipient derived for ${machine} is not an age key"
  mkdir -p "$out/$machine"

  # Every machine reads every cache: its netrc fragment for THIS cache.
  { printf 'machine %s\npassword ' "$CACHE_FQDN" && mint "$machine" "$readValidity" --pull "$CACHE_NAME"; } |
    age -r "$recipient" -o "$out/$machine/netrc.$METALSPACE.age.tmp" ||
    die "issuing ${machine}'s read token failed — nothing written for it"
  mv "$out/$machine/netrc.$METALSPACE.age.tmp" "$out/$machine/netrc.$METALSPACE.age"
  issued=$((issued + 1))

  # Only this metalspace's own machines write into this cache.
  if [ "$machineMetalspace" = "$METALSPACE" ]; then
    mint "$machine" "$writeValidity" --push "$CACHE_NAME" --pull "$CACHE_NAME" |
      age -r "$recipient" -o "$out/$machine/write.token.age.tmp" ||
      die "issuing ${machine}'s write token failed — its read fragment is written, its write token is not"
    mv "$out/$machine/write.token.age.tmp" "$out/$machine/write.token.age"
    issued=$((issued + 1))
  fi
  log "${machine}: issued for ${recipient}"
done <<<"$TARGETS"

log "done: ${issued} ciphertext file(s) under ${out}, nothing in clear"
find "$out" -name '*.age' -printf '%P\n' | sort
