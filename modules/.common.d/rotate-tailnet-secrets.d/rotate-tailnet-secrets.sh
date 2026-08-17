#!/usr/bin/env -S bash -euo pipefail
# rotate-tailnet-secrets — manage the per-kind Tailscale SaaS auth keys in
# .secrets, using the long-lived OAuth client at tailnet.tailscale.client.
#
# Two actions (composable):
#   --rotate-auth-key : mint one reusable, pre-authorized, tagged auth key per
#                       host-kind (baked from catalog.tailnet.tags at @authKinds@)
#                       and write it to tailnet.tailscale.auth.<kind> via a
#                       targeted, atomic `sops set`.
#   --sync-acl        : reconcile the LIVE tailnet ACL with our canonical
#                       fragment (@aclCanonical@) — GET current + ETag, merge
#                       (prune superseded tags, set our tag vocabulary + owners,
#                       role-based acls/ssh, baremetal route auto-approvers;
#                       preserve personal/k8s tags, nodeAttrs, other routes),
#                       show a diff, POST with If-Match only under --yes.
#
# Base: the shared bash trampoline (nix-managed bash + logger + stable env).
# Tools are pinned by absolute store path (@sops@/@curl@/@yq@) — yq-go only,
# no jq: all structured-document parsing goes through yq.
#
# Safe by default: nothing is minted, written, revoked, or POSTed unless the
# matching flag (+ --yes for destructive/remote writes) is given.  Logging runs
# under ndh::logger:command:run (xtrace on) — the operator's private logs are
# the debug surface here.
source @nixBashTrampoline@

readonly SOPS="@sops@"
readonly CURL="@curl@"
readonly YQ="@yq@"
readonly AUTH_KINDS_FILE="@authKinds@"
export ACL_CANONICAL="@aclCanonical@" # exported so yq's load(strenv(...)) can read it

readonly API_BASE="https://api.tailscale.com/api/v2"
readonly TAILNET="-" # "-" = the OAuth identity's default tailnet
readonly SECRETS_FILE=".secrets"
readonly CLIENT_INDEX='["tailnet"]["tailscale"]["client"]'
readonly OWNER_TAG="tag:tailnet-key-owner"

# Option state (globals; set by main, read by helpers).
dry_run=1
do_auth=0
do_api=0
do_sync_acl=0
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

Safe by default. Manages the per-kind Tailscale SaaS auth keys + the ACL.

  --dry-run          Show planned actions, change nothing (default).
  --rotate-auth-key  Mint fresh per-kind auth keys and write .secrets.
  --rotate-api-key   NOT SUPPORTED (explained at runtime).
  --rotate-both      Same as --rotate-auth-key (api keys can't be API-rotated).
  --sync-acl         Reconcile the live tailnet ACL with our canonical fragment;
                     shows a diff.  POSTs only with --yes.
  --kind <kind>      Restrict rotation to a single kind (default: all).
  --deploy           Print the post-rotation rebuild commands (never runs them).
  --revoke-old       Revoke the auth keys that existed before this run.
                     Requires --yes.  Runs only after new keys are written.
  --yes              Confirm destructive / remote-write actions (ACL POST, revoke).
  -h, --help         This help.
EOF
}

# Exchange the OAuth client secret for a short-lived API token; stash it in a
# curl config file (the client secret goes to a file via a pipe, not an argv).
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

# Reconcile the live tailnet ACL with @aclCanonical@.  Additive + rationalising:
# prune the superseded tags (operator/service/container) and the obsolete
# personal ones (work/committed/github — every host is owner-exclusive now),
# set our tag vocabulary + owners, replace acls/ssh with the role-based
# canonical, merge our route + exit-node auto-approvers; preserve the rest
# (k8s tagOwners, nodeAttrs, existing routes).
sync_acl() {
  local etag
  $CURL -fsS -D "$workdir/acl.hdr" -K "$workdir/auth.conf" -H 'Accept: application/json' \
    "$API_BASE/tailnet/$TAILNET/acl" >"$workdir/acl.cur.json" || die "GET acl failed"
  etag="$(sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' "$workdir/acl.hdr" | tr -d '\r')"

  $YQ -p json -o=json '
    .tagOwners = (
      ((.tagOwners // {})
        | del(.["tag:operator"]) | del(.["tag:service"]) | del(.["tag:container"])
        | del(.["tag:work"]) | del(.["tag:committed"]) | del(.["tag:github"]))
      * load(strenv(ACL_CANONICAL)).tagOwners)
    | .acls = load(strenv(ACL_CANONICAL)).acls
    | .ssh  = load(strenv(ACL_CANONICAL)).ssh
    | .autoApprovers.routes = ((.autoApprovers.routes // {}) * load(strenv(ACL_CANONICAL)).autoApprovers.routes)
    | .autoApprovers.exitNode = (((.autoApprovers.exitNode // []) + load(strenv(ACL_CANONICAL)).autoApprovers.exitNode) | unique)
  ' "$workdir/acl.cur.json" >"$workdir/acl.target.json" || die "ACL reconcile failed"

  log "=== ACL reconcile diff (current -> target) ==="
  diff -u \
    <($YQ -p json -o=yaml '.' "$workdir/acl.cur.json") \
    <($YQ -p json -o=yaml '.' "$workdir/acl.target.json") || true
  log "NOTE: for minting to work, assign '$OWNER_TAG' to the rotation OAuth"
  log "      client in the Tailscale console (Settings -> OAuth clients)."

  if [ "$assume_yes" -ne 1 ]; then
    log "no --yes: ACL not pushed.  Re-run 'rotate-tailnet-secrets --sync-acl --yes' to POST."
    return 0
  fi
  $CURL -fsS -X POST -K "$workdir/auth.conf" -H 'Content-Type: application/json' \
    ${etag:+-H "If-Match: $etag"} --data-binary "@$workdir/acl.target.json" \
    "$API_BASE/tailnet/$TAILNET/acl" >/dev/null ||
    die "POST acl failed (If-Match/ETag conflict or policy validation)"
  log "SaaS ACL updated (reconciled)."
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

rotation_plan() {
  local spec k t
  log "DRY-RUN — no mint, no write.  Planned per-kind auth keys:"
  for spec in "${specs[@]}"; do
    k="$(printf '%s' "$spec" | $YQ -p json '.kind')"
    want_kind "$k" || continue
    t="$(printf '%s' "$spec" | $YQ -p json '.tags | join(",")')"
    log "  $k: tags=$t  reusable preauthorized expiry=90d  -> tailnet.tailscale.auth.$k"
  done
  log "tailnet has $(list_key_ids | grep -c . || true) existing auth key(s)."
  log "Actions: --rotate-auth-key (mint + write; --revoke-old --yes to retire old);"
  log "         --sync-acl (review/reconcile the tailnet ACL; --sync-acl --yes to push)."
  log "See --help for the full option list."
}

rotate_auth() {
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
  for spec in "${specs[@]}"; do
    k="$(printf '%s' "$spec" | $YQ -p json '.kind')"
    want_kind "$k" || continue
    $SOPS -d --input-type yaml --extract "[\"tailnet\"][\"tailscale\"][\"auth\"][\"$k\"]" \
      "$SECRETS_FILE" 2>/dev/null | grep -q '^tskey-auth-' ||
      die "post-write verify failed for kind=$k"
  done
  log "per-kind auth keys rotated + verified."
}

revoke_old() {
  [ "$assume_yes" -eq 1 ] ||
    die "--revoke-old requires --yes (destructive: revokes pre-existing auth keys)"
  log "revoking pre-existing auth keys (snapshot taken before mint) …"
  local oid
  while IFS= read -r oid; do
    [ -n "$oid" ] || continue
    grep -qx "$oid" "$workdir/new_ids" && continue # never revoke one we just minted
    if revoke_key "$oid"; then log "  revoked $oid"; else warn "  failed to revoke $oid"; fi
  done <"$workdir/old_ids"
}

specs=()

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
      --sync-acl) do_sync_acl=1 ;;
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
  [ -r "$ACL_CANONICAL" ] || die "acl canonical missing: $ACL_CANONICAL"
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
    { [ "$do_auth" -eq 1 ] || [ "$do_sync_acl" -eq 1 ]; } || exit 1
  fi

  mapfile -t specs < <($YQ -p json -o=json -I=0 '.[]' "$AUTH_KINDS_FILE")

  log "controller: Tailscale SaaS"
  log "kinds: $($YQ -p json '[.[].kind] | join(", ")' "$AUTH_KINDS_FILE")${only_kind:+  (restricted to: $only_kind)}"

  authenticate

  [ "$do_sync_acl" -eq 1 ] && sync_acl

  if [ "$do_auth" -eq 1 ]; then
    list_key_ids >"$workdir/old_ids" || true
    : >"$workdir/new_ids"
    rotate_auth
    [ "$do_revoke" -eq 1 ] && revoke_old
    if [ "$do_deploy" -eq 1 ]; then
      log "post-rotation deploy — run these yourself (this tool never mutates a live host):"
      log "  sudo nixos-rebuild switch --flake .#nikopol-nixos --refresh"
      log "  (repeat per host that consumes a rotated kind)"
    fi
  elif [ "$dry_run" -eq 1 ] && [ "$do_sync_acl" -eq 0 ]; then
    rotation_plan
  fi

  log "done."
}

ndh::logger:command:run "@loggerTag@" main "$@"
