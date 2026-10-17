# ★ xtrace-guard — no trace, whatever the invocation: with --apply this script hands a cachix push
# token to cachix, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles a push token" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true
unset BASH_XTRACEFD 2>/dev/null || true

# cache-publish — the PUBLIC level's only feeder (docs/private-binary-cache-spec.adoc,
# public-private-split): from ONE revision, build the allow-listed outputs, compute the publishable
# part of their closure, and push exactly that to the public cache. Never a watch-store: nothing
# reaches the public cache because it appeared in a store.
#
# A path of the closure is publishable when an upstream cache already serves it, or when it is built
# (it has a deriver), passes the content guard, and every path it references is publishable. Anything
# else, and everything that reaches it, stays private: an added path (a -source, a sops-nix file),
# an aggregate (etc, home-manager-files…). Dry run by default; --apply pushes, then checks that the
# public cache holds every published path and none of the private ones.
#
# Env, fixed at eval: OUTPUTS (one flake attribute per line), CACHE (the cachix cache), PUBLIC_URL
# (its substituter), UPSTREAMS (one substituter URL per line), TOKEN_FILE (the push token, read by
# --apply only), JOBS (parallel narinfo queries).
# Usage: cache-publish [--apply] <flake ref naming a revision, ?rev=<40 hex> or /<40 hex>>
apply=0
if [ "${1:-}" = --apply ]; then
  apply=1
  shift
fi
ref="${1:?usage: cache-publish [--apply] <flake ref naming a revision>}"

log() { printf '[cache-publish] %s\n' "$*" >&2; }
die() {
  printf '[cache-publish] ERROR: %s\n' "$*" >&2
  exit 1
}

# Revisions only: a ref without a full revision could name a working tree, whose evaluation copies
# its decrypted secrets into the store (the 2026-10-10 leak).
[[ $ref =~ [?\&]rev=[0-9a-f]{40}($|\&) || $ref =~ ^github:[^?]+/[0-9a-f]{40}$ ]] ||
  die "not a revision: ${ref} — name one with ?rev=<40 hex>"
[[ $ref != path:* && $ref != /* && $ref != .* ]] || die "a path is not a revision: ${ref}"
[ -n "$OUTPUTS" ] || die "no output on the allow-list"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

roots=()
attrs=0
while read -r attr; do
  [ -n "$attr" ] || continue
  out="$(nix build --no-link --print-out-paths "${ref}#${attr}")" || die "building ${attr} failed"
  mapfile -t built <<<"$out"
  roots+=("${built[@]}")
  attrs=$((attrs + 1))
done <<<"$OUTPUTS"
log "built ${attrs} allow-listed attribute(s) into ${#roots[@]} output(s)"

# path <TAB> deriver <TAB> references (space-separated, without the path itself)
nix path-info --recursive --json "${roots[@]}" |
  yq -p json -o tsv 'to_entries | .[] | [.key, (.value.deriver // ""), ((.value.references // []) - [.key] | join(" "))]' \
    >"$work/closure.tsv" || die "reading the closure failed"

# Served upstream: a narinfo answering 200 on any upstream substituter.
upstream_of() { # <path> → prints the path if an upstream serves it
  local hash url
  hash="$(basename "$1" | cut -d- -f1)"
  while read -r url; do
    [ -n "$url" ] || continue
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${url%/}/${hash}.narinfo")" = 200 ]; then
      printf '%s\n' "$1"
      return
    fi
  done <<<"$UPSTREAMS"
}
export -f upstream_of
export UPSTREAMS
# shellcheck disable=SC2016 # $1 is the inner bash's, intentionally single-quoted
cut -f1 "$work/closure.tsv" | xargs -P "${JOBS:-16}" -I{} bash -c 'upstream_of "$1"' _ {} | sort >"$work/upstream"

# The content guard (the shapes of rke2lab's token_shape_guard, and AWS's: the sessions reach Bedrock
# through an AWS profile on these machines): a hit makes the path private.
guard_hits() { # <path> → exit 0 when the path carries a secret shape
  LC_ALL=C grep -a -r -l -q -E \
    'AGE-SECRET-KEY-1[A-Z0-9]{50,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|tskey-[A-Za-z0-9-]{16,}|gh[opsu]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|dckr_pat_[A-Za-z0-9_-]{20,}|glpat-[A-Za-z0-9_-]{20,}|(^|[^A-Z0-9])(AKIA|ASIA)[A-Z0-9]{16}([^A-Z0-9]|$)|aws_(secret_access_key|session_token)["'\'']?[[:space:]]*[=:][[:space:]]*["'\'']?[A-Za-z0-9/+=]{20,}' \
    "$1" && return 0
  # A private-key armour WITH a body, or a sops annotation not followed by ENC[.
  # shellcheck disable=SC2016 # awk's $0, intentionally single-quoted
  LC_ALL=C find "$1" -type f -print0 | xargs -0 -r awk '
    FNR == 1 { prev = "" }
    prev ~ /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/ && $0 ~ /^[A-Za-z0-9+\/=]{40,}$/ { print "HIT"; exit }
    prev ~ /# sops:encrypted/ && $0 !~ /ENC\[/ { print "HIT"; exit }
    { prev = $0 }' 2>/dev/null | grep -q HIT
}

declare -A private=() deriver=() refs=()
while IFS=$'\t' read -r path drv references; do
  deriver[$path]="$drv"
  refs[$path]="$references"
done <"$work/closure.tsv"
declare -A served=()
while read -r path; do served[$path]=1; done <"$work/upstream"

for path in "${!deriver[@]}"; do
  [ -z "${served[$path]:-}" ] || continue
  if [ -z "${deriver[$path]}" ] || [ "${deriver[$path]}" = unknown-deriver ]; then
    private[$path]=added
  elif guard_hits "$path"; then
    private[$path]=guard
  fi
done
log "$(printf '%s\n' "${private[@]}" | grep -c guard || true) path(s) held back by the content guard"

# Everything that reaches a private path is private too: propagate until nothing changes.
changed=1
while [ "$changed" = 1 ]; do
  changed=0
  for path in "${!deriver[@]}"; do
    if [ -n "${served[$path]:-}" ] || [ -n "${private[$path]:-}" ]; then continue; fi
    read -ra references <<<"${refs[$path]}"
    for r in "${references[@]}"; do
      if [ -n "${private[$r]:-}" ]; then
        private[$path]=reaches
        changed=1
        break
      fi
    done
  done
done

: >"$work/publish"
for path in "${!deriver[@]}"; do
  if [ -z "${served[$path]:-}" ] && [ -z "${private[$path]:-}" ]; then
    printf '%s\n' "$path" >>"$work/publish"
  fi
done
sort -o "$work/publish" "$work/publish"
log "closure ${#deriver[@]} · upstream ${#served[@]} · private ${#private[@]} · publishable $(wc -l <"$work/publish")"
for path in "${!private[@]}"; do printf 'private %s %s\n' "${private[$path]}" "$path"; done | sort
sed 's/^/publish /' "$work/publish"

if [ "$apply" = 0 ]; then
  log "dry run: nothing pushed (--apply pushes the publishable set)"
  exit 0
fi

[ -r "$TOKEN_FILE" ] || die "the push token is not readable: ${TOKEN_FILE}"
# cachix reads its token from its own config, written in a throwaway HOME: never an argument nor the
# environment.
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
mkdir -p "$XDG_CONFIG_HOME"
cachix authtoken --stdin <"$TOKEN_FILE" >/dev/null || die "cachix refused the push token"
cachix push "$CACHE" <"$work/publish" || die "the push failed"

# The public cache holds exactly the computed set: every published path, and no private one.
missing=0 leaked=0
while read -r path; do
  hash="$(basename "$path" | cut -d- -f1)"
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${PUBLIC_URL%/}/${hash}.narinfo")" = 200 ] ||
    { log "missing after the push: ${path}"; missing=$((missing + 1)); }
done <"$work/publish"
for path in "${!private[@]}"; do
  hash="$(basename "$path" | cut -d- -f1)"
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${PUBLIC_URL%/}/${hash}.narinfo")" != 200 ] ||
    { log "⛔ PRIVATE path served by the public cache: ${path}"; leaked=$((leaked + 1)); }
done
[ "$leaked" = 0 ] || die "${leaked} private path(s) are public — purge them from ${CACHE} now"
[ "$missing" = 0 ] || die "${missing} published path(s) are not served"
log "published $(wc -l <"$work/publish") path(s) to ${CACHE}; none of the ${#private[@]} private ones is served"
