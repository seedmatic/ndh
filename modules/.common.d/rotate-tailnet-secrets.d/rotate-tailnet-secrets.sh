#!/usr/bin/env -S bash -euo pipefail
# rotate-tailnet-secrets — rotate the per-kind Tailscale SaaS auth keys in
# .secrets, using the long-lived OAuth client at tailnet.tailscale.client.
#
# For each host-kind (baked in from catalog.tailnet.tags at @authKinds@) it
# mints one reusable, pre-authorized, tagged auth key and writes it to
# tailnet.tailscale.auth.<kind> via a targeted, atomic `sops set`.
#
# Base: the shared bash trampoline (nix-managed bash + logger + stable env).
# Tools are pinned by absolute store path (@sops@/@curl@/@yq@) — yq-go only,
# no jq: all structured-document parsing goes through yq.  The per-kind POST
# bodies are built in Nix (at @authKinds@) so the script only reads/extracts.
#
# Safe by default: nothing is minted, written, or revoked unless a --rotate-*
# flag is given.  Logging runs under ndh::logger:command:run (xtrace on) — the
# operator's private logs are the debug surface here.
source @nixBashTrampoline@

readonly SOPS="@sops@"
readonly CURL="@curl@"
readonly YQ="@yq@"
readonly AUTH_KINDS_FILE="@authKinds@"

readonly API_BASE="https://api.tailscale.com/api/v2"
readonly TAILNET="-" # "-" = the OAuth identity's default tailnet
readonly SECRETS_FILE=".secrets"
readonly CLIENT_INDEX='["tailnet"]["tailscale"]["client"]'

# Option state (globals; set by main, read by helpers).
dry_run=1
do_auth=0
do_api=0
do_deploy=0
do_revoke=0
assume_yes=0
only_kind=""
workdir=""

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

# Exchange the OAuth client secret for a short-lived API token; stash it in a
# curl config file.  The client secret goes to a file (not an argv) via a pipe.
authenticate() {
  $SOPS -d --input-type yaml --extract "$CLIENT_INDEX" "$SECRETS_FILE" \
    >"$workdir/client" 2>/dev/null || die "could not decrypt tailnet.tailscale.client (sops)"
  [ -s "$workdir/client" ] || die "tailnet.tailscale.client is empty"
  grep -q '^tskey-client-' "$workdir/client" ||
    die "tailnet.tailscale.client has an unexpected prefix (want tskey-client-…)"
  local token
  token="$($CURL -fsS --data-urlencode "client_secret@$workdir/client" \
    "$API_BASE/oauth/token" | $YQ -p json '.access_token')" ||
    die "OAuth token exchange failed (network / credentials)"
  rm -f "$workdir/client"
  { [ -n "$token" ] && [ "$token" != "null" ]; } ||
    die "OAuth token exchange returned no access_token"
  printf 'header = "Authorization: Bearer %s"\n' "$token" >"$workdir/auth.conf"
}

list_key_ids() {
  $CURL -fsS -K "$workdir/auth.conf" "$API_BASE/tailnet/$TAILNET/keys" 2>/dev/null |
    $YQ -p json '.keys[].id' 2>/dev/null || true
}

revoke_key() {
  $CURL -fsS -X DELETE -K "$workdir/auth.conf" \
    "$API_BASE/tailnet/$TAILNET/keys/$1" >/dev/null 2>&1
}

# Migrate the legacy scalar tailnet.tailscale.auth to an empty map so per-kind
# keys can nest under it.  No-op once it is already a map.
ensure_auth_map() {
  local t
  t="$($SOPS -d --input-type yaml --output-type json "$SECRETS_FILE" 2>/dev/null |
    $YQ -p json '.tailnet.tailscale.auth | tag')" || die "cannot read auth node type"
  if [ "$t" != "!!map" ]; then
    log "migrating tailnet.tailscale.auth (legacy scalar) -> per-kind map"
    $SOPS set --input-type yaml "$SECRETS_FILE" \
      '["tailnet"]["tailscale"]["auth"]' '{}' || die "auth scalar->map migration failed"
  fi
}

# Mint one tagged auth key for a kind (pre-built body) and write it to its slot.
# The key flows API-response -> yq -> sops stdin.  Appends the id to new_ids.
mint_and_write() {
  local kind="$1" body="$2" resp index
  resp="$($CURL -fsS -K "$workdir/auth.conf" -H 'Content-Type: application/json' \
    -d "$body" "$API_BASE/tailnet/$TAILNET/keys" 2>/dev/null)" ||
    die "mint failed for kind=$kind (API error — check OAuth scope + ACL tagOwners)"
  printf '%s' "$resp" | $YQ -p json '.key' | grep -q '^tskey-auth-' ||
    die "mint for kind=$kind returned no/invalid key"
  index="[\"tailnet\"][\"tailscale\"][\"auth\"][\"$kind\"]"
  printf '%s' "$resp" | $YQ -p json -o=json '.key' |
    $SOPS set --input-type yaml --value-stdin "$SECRETS_FILE" "$index" ||
    die "sops write failed for kind=$kind"
  printf '%s' "$resp" | $YQ -p json '.id' >>"$workdir/new_ids"
}

want_kind() { [ -z "$only_kind" ] || [ "$1" = "$only_kind" ]; }

main() {
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

  # preflight
  [ -f "$SECRETS_FILE" ] || die "run from the repo root: $SECRETS_FILE not found"
  [ -r "$AUTH_KINDS_FILE" ] || die "kinds manifest missing: $AUTH_KINDS_FILE"
  # .secrets must be sops-encrypted at rest (a sops file carries a top-level
  # `sops:` metadata block — guards against a smudged/plaintext working tree).
  local sops_version
  sops_version="$($YQ '.sops.version' "$SECRETS_FILE" 2>/dev/null || true)"
  { [ -n "$sops_version" ] && [ "$sops_version" != "null" ]; } ||
    die "$SECRETS_FILE is not sops-encrypted at rest (no .sops metadata); refusing"

  umask 077
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/rotate-tailnet.XXXXXX")"
  trap 'rm -rf "$workdir"' EXIT INT TERM

  if [ "$do_api" -eq 1 ]; then
    warn "api-key rotation is NOT supported via the API: Tailscale API keys are"
    warn "console-only and cannot rotate themselves.  The long-lived OAuth client"
    warn "(tailnet.tailscale.client) supersedes the legacy tailnet.tailscale.api"
    warn "slot for automation — retire it in the console once you've cut over."
    [ "$do_auth" -eq 1 ] || exit 1
  fi

  log "controller: Tailscale SaaS"
  log "kinds: $($YQ -p json '[.[].kind] | join(", ")' "$AUTH_KINDS_FILE")${only_kind:+  (restricted to: $only_kind)}"

  mapfile -t specs < <($YQ -p json -o=json -I=0 '.[]' "$AUTH_KINDS_FILE")

  if [ "$dry_run" -eq 1 ]; then
    log "DRY-RUN — no mint, no write, no revoke.  Planned per-kind auth keys:"
    local spec k t
    for spec in "${specs[@]}"; do
      k="$(printf '%s' "$spec" | $YQ -p json '.kind')"
      want_kind "$k" || continue
      t="$(printf '%s' "$spec" | $YQ -p json '.tags | join(",")')"
      log "  $k: tags=$t  reusable preauthorized expiry=90d  -> tailnet.tailscale.auth.$k"
    done
    authenticate
    log "OAuth credential OK (token exchange succeeded); tailnet has $(list_key_ids | grep -c . || true) existing auth key(s)."
    log "Re-run with --rotate-auth-key to mint + write (add --revoke-old --yes to retire the old ones)."
    return 0
  fi

  authenticate
  list_key_ids >"$workdir/old_ids" || true
  : >"$workdir/new_ids"

  if [ "$do_auth" -eq 1 ]; then
    ensure_auth_map
    local spec k body
    for spec in "${specs[@]}"; do
      k="$(printf '%s' "$spec" | $YQ -p json '.kind')"
      want_kind "$k" || continue
      body="$(printf '%s' "$spec" | $YQ -p json -o=json -I=0 '.body')"
      log "minting $k (tags=$(printf '%s' "$spec" | $YQ -p json '.tags | join(",")')) …"
      mint_and_write "$k" "$body"
      log "  wrote tailnet.tailscale.auth.$k"
    done
    # Post-write verify: decrypt + prefix-check each slot (value never printed).
    for spec in "${specs[@]}"; do
      k="$(printf '%s' "$spec" | $YQ -p json '.kind')"
      want_kind "$k" || continue
      $SOPS -d --input-type yaml --extract "[\"tailnet\"][\"tailscale\"][\"auth\"][\"$k\"]" \
        "$SECRETS_FILE" 2>/dev/null | grep -q '^tskey-auth-' ||
        die "post-write verify failed for kind=$k"
    done
    log "per-kind auth keys rotated + verified."
  fi

  if [ "$do_revoke" -eq 1 ]; then
    [ "$assume_yes" -eq 1 ] ||
      die "--revoke-old requires --yes (destructive: revokes pre-existing auth keys)"
    log "revoking pre-existing auth keys (snapshot taken before mint) …"
    local oid
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
}

ndh::logger:command:run "@loggerTag@" main "$@"
