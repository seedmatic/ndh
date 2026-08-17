# rotate-tailnet-secrets — rotate the per-kind Tailscale SaaS auth keys in
# .secrets, using the long-lived OAuth client at tailnet.tailscale.client.
#
# For each host-kind (tags baked in from catalog.tailnet.tags) it mints one
# reusable, pre-authorized, tagged auth key and writes it to
# tailnet.tailscale.auth.<kind> via a targeted, atomic `sops set`.
#
# Safe by default: nothing is minted, written, or revoked unless a --rotate-*
# flag is given.  Secret VALUES are never printed (only ids, which are not
# secret).  Authentication is the OAuth client exchanged for a short-lived API
# token — the raw client secret in a Bearer header is rejected by Tailscale
# (403), so the token-exchange flow is the only path.
#
# Kinds + tag pairs are provided at build time via $NDH_TAILNET_AUTH_KINDS_FILE
# (nix-store JSON: [{"kind":"nixos","tags":["tag:headless","tag:nixos"]},…]).
#
# writeShellApplication supplies the shebang and `set -euo pipefail`.

umask 077

API_BASE="https://api.tailscale.com/api/v2"
TAILNET="-" # "-" = the OAuth identity's default tailnet
EXPIRY_SECONDS=7776000 # 90 days (Tailscale auth-key maximum)
SECRETS_FILE=".secrets"
CLIENT_INDEX='["tailnet"]["tailscale"]["client"]'

log() { printf '%s\n' ":: $*"; }
warn() { printf '%s\n' "!! $*" >&2; }
die() {
  printf '%s\n' "xx $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: rotate-tailnet-secrets [options]   (run from the repo root)

Safe by default (dry-run). Rotates the per-kind Tailscale SaaS auth keys.

  --dry-run          Show planned actions, change nothing (default).
  --rotate-auth-key  Mint fresh per-kind auth keys and write .secrets.
  --rotate-api-key   NOT SUPPORTED (explained at runtime).
  --rotate-both      Same as --rotate-auth-key (api keys can't be API-rotated).
  --kind <kind>      Restrict to a single kind (default: all catalog kinds).
  --deploy           Print the post-rotation rebuild commands (never runs them).
  --revoke-old       Revoke the auth keys that existed before this run.
                     Requires --yes.  Runs only after new keys are written.
  --yes              Confirm destructive actions (revocation).
  -h, --help         This help.
EOF
}

dry_run=1
do_auth=0
do_api=0
do_deploy=0
do_revoke=0
assume_yes=0
only_kind=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --rotate-auth-key)
      do_auth=1
      dry_run=0
      ;;
    --rotate-api-key)
      do_api=1
      dry_run=0
      ;;
    --rotate-both)
      do_auth=1
      do_api=1
      dry_run=0
      ;;
    --kind)
      shift
      only_kind="${1:-}"
      [ -n "$only_kind" ] || die "--kind needs an argument"
      ;;
    --deploy) do_deploy=1 ;;
    --revoke-old) do_revoke=1 ;;
    --yes) assume_yes=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      warn "unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

# --- preflight ------------------------------------------------------------
for tool in sops curl jq yq; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
[ -f "$SECRETS_FILE" ] || die "run from the repo root: $SECRETS_FILE not found"
{ [ -n "${NDH_TAILNET_AUTH_KINDS_FILE:-}" ] && [ -r "$NDH_TAILNET_AUTH_KINDS_FILE" ]; } ||
  die "kinds manifest missing (NDH_TAILNET_AUTH_KINDS_FILE)"
# .secrets must be sops-encrypted at rest (guards against a smudged/plaintext
# working tree — a sops file always carries a top-level `sops:` metadata block).
yq -e '.sops.version' "$SECRETS_FILE" >/dev/null 2>&1 ||
  die "$SECRETS_FILE is not sops-encrypted at rest (no .sops metadata); refusing"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/rotate-tailnet.XXXXXX")"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT INT TERM

# --- helpers --------------------------------------------------------------
# Exchange the OAuth client secret for a short-lived API token and stash it in
# a curl config file (so the token never appears in a process argument list).
authenticate() {
  local client token
  client="$(sops -d --input-type yaml --extract "$CLIENT_INDEX" "$SECRETS_FILE" 2>/dev/null)" ||
    die "could not decrypt tailnet.tailscale.client (sops)"
  [ -n "$client" ] || die "tailnet.tailscale.client is empty"
  case "$client" in
    tskey-client-*) : ;;
    *) die "tailnet.tailscale.client has an unexpected prefix (want tskey-client-…)" ;;
  esac
  printf '%s' "$client" >"$workdir/client"
  token="$(curl -fsS --data-urlencode "client_secret@$workdir/client" \
    "$API_BASE/oauth/token" 2>/dev/null | jq -r '.access_token // empty')" ||
    die "OAuth token exchange failed (network / credentials)"
  rm -f "$workdir/client"
  [ -n "$token" ] || die "OAuth token exchange returned no access_token"
  printf 'header = "Authorization: Bearer %s"\n' "$token" >"$workdir/auth.conf"
}

list_key_ids() {
  curl -fsS -K "$workdir/auth.conf" "$API_BASE/tailnet/$TAILNET/keys" 2>/dev/null |
    jq -r '.keys[].id' 2>/dev/null || true
}

revoke_key() {
  curl -fsS -X DELETE -K "$workdir/auth.conf" \
    "$API_BASE/tailnet/$TAILNET/keys/$1" >/dev/null 2>&1
}

# Migrate the legacy scalar tailnet.tailscale.auth to an empty map so per-kind
# keys can be nested under it.  No-op once it is already a map.
ensure_auth_map() {
  local t
  t="$(sops -d --input-type yaml "$SECRETS_FILE" 2>/dev/null |
    yq -r '.tailnet.tailscale.auth | type')" || die "cannot read auth node type"
  if [ "$t" != "!!map" ]; then
    log "migrating tailnet.tailscale.auth (legacy scalar) -> per-kind map"
    sops set --input-type yaml "$SECRETS_FILE" \
      '["tailnet"]["tailscale"]["auth"]' '{}' || die "auth scalar->map migration failed"
  fi
}

# Mint one tagged auth key for a kind and write it to its slot.  The key value
# flows API-response -> jq -> sops stdin without ever touching a shell variable
# or an argument list.  Appends the new key id to $workdir/new_ids.
mint_and_write() {
  local kind="$1" tags_json="$2" body resp newid index
  body="$(jq -cn --argjson tags "$tags_json" --argjson exp "$EXPIRY_SECONDS" \
    --arg desc "ndh $kind per-kind auth key" \
    '{capabilities:{devices:{create:{reusable:true,ephemeral:false,preauthorized:true,tags:$tags}}},expirySeconds:$exp,description:$desc}')"
  resp="$(curl -fsS -K "$workdir/auth.conf" -H 'Content-Type: application/json' \
    -d "$body" "$API_BASE/tailnet/$TAILNET/keys" 2>/dev/null)" ||
    die "mint failed for kind=$kind (API error — check OAuth scope + ACL tagOwners for $tags_json)"
  printf '%s' "$resp" | jq -e '.key | strings | startswith("tskey-auth-")' >/dev/null 2>&1 ||
    die "mint for kind=$kind returned no/invalid key"
  newid="$(printf '%s' "$resp" | jq -r '.id // empty')"
  index="[\"tailnet\"][\"tailscale\"][\"auth\"][\"$kind\"]"
  printf '%s' "$resp" | jq '.key' |
    sops set --input-type yaml --value-stdin "$SECRETS_FILE" "$index" ||
    die "sops write failed for kind=$kind"
  printf '%s\n' "$newid" >>"$workdir/new_ids"
}

want_kind() { [ -z "$only_kind" ] || [ "$1" = "$only_kind" ]; }

# --- plan -----------------------------------------------------------------
mapfile -t specs < <(jq -c '.[]' "$NDH_TAILNET_AUTH_KINDS_FILE")

if [ "$do_api" -eq 1 ]; then
  warn "api-key rotation is NOT supported via the API: Tailscale API keys are"
  warn "console-only and cannot rotate themselves.  The long-lived OAuth client"
  warn "(tailnet.tailscale.client) supersedes the legacy tailnet.tailscale.api"
  warn "slot for automation — retire it in the console once you've cut over."
  [ "$do_auth" -eq 1 ] || exit 1
fi

log "controller: Tailscale SaaS"
log "kinds: $(jq -r 'map(.kind)|join(", ")' "$NDH_TAILNET_AUTH_KINDS_FILE")${only_kind:+  (restricted to: $only_kind)}"

if [ "$dry_run" -eq 1 ]; then
  log "DRY-RUN — no mint, no write, no revoke.  Planned per-kind auth keys:"
  for spec in "${specs[@]}"; do
    k="$(printf '%s' "$spec" | jq -r '.kind')"
    want_kind "$k" || continue
    t="$(printf '%s' "$spec" | jq -r '.tags|join(",")')"
    log "  $k: tags=$t  reusable preauthorized expiry=90d  -> tailnet.tailscale.auth.$k"
  done
  authenticate
  n="$(list_key_ids | grep -c . || true)"
  log "OAuth credential OK (token exchange succeeded); tailnet has $n existing auth key(s)."
  log "Re-run with --rotate-auth-key to mint + write (add --revoke-old --yes to retire the old ones)."
  exit 0
fi

# --- execute --------------------------------------------------------------
authenticate
list_key_ids >"$workdir/old_ids" || true
: >"$workdir/new_ids"

if [ "$do_auth" -eq 1 ]; then
  ensure_auth_map
  for spec in "${specs[@]}"; do
    k="$(printf '%s' "$spec" | jq -r '.kind')"
    want_kind "$k" || continue
    tags_json="$(printf '%s' "$spec" | jq -c '.tags')"
    log "minting $k (tags=$(printf '%s' "$spec" | jq -r '.tags|join(",")')) …"
    mint_and_write "$k" "$tags_json"
    log "  wrote tailnet.tailscale.auth.$k"
  done
  # Post-write verify: decrypt + prefix-check each slot (value never printed).
  for spec in "${specs[@]}"; do
    k="$(printf '%s' "$spec" | jq -r '.kind')"
    want_kind "$k" || continue
    sops -d --input-type yaml --extract "[\"tailnet\"][\"tailscale\"][\"auth\"][\"$k\"]" \
      "$SECRETS_FILE" 2>/dev/null | grep -q '^tskey-auth-' ||
      die "post-write verify failed for kind=$k"
  done
  log "per-kind auth keys rotated + verified (values never printed)."
fi

if [ "$do_revoke" -eq 1 ]; then
  [ "$assume_yes" -eq 1 ] ||
    die "--revoke-old requires --yes (destructive: revokes pre-existing auth keys)"
  log "revoking pre-existing auth keys (snapshot taken before mint) …"
  while IFS= read -r oid; do
    [ -n "$oid" ] || continue
    grep -qx "$oid" "$workdir/new_ids" && continue # never revoke one we just minted
    if revoke_key "$oid"; then log "  revoked $oid"; else warn "  failed to revoke $oid"; fi
  done <"$workdir/old_ids"
fi

if [ "$do_deploy" -eq 1 ]; then
  log "post-rotation deploy — run these yourself (this tool never mutates a live host):"
  log "  sudo nixos-rebuild switch --flake .#nikopol-nixos --refresh"
  log "  (repeat per host that consumes a rotated kind)"
fi

log "done."
