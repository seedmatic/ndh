#!/usr/bin/env -S bash -euo pipefail
# manage-tailnet — administer the Tailscale SaaS tailnet via the long-lived
# OAuth client at tailnet.tailscale.client: rotate per-kind auth keys, reconcile
# the ACL, retag devices, and prune stale (orphaned) devices.
#
# Actions (composable):
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
#   --retag-devices   : reconcile each device's tags to its kind (from hostname).
#   --prune-stale-devices : delete tagged devices offline > --stale-after — the
#                       orphaned operator proxies a cluster re-grow leaves behind
#                       (no teardown removes them), which hold MagicDNS names.
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
readonly GIT="@git@"
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
do_sync_acl=0
do_retag=0
do_prune=0
do_deploy=0
do_revoke=0
do_commit=0
assume_yes=0
stale_after="1h"
only_kind=""
workdir=""
TOKEN=""

# log() narrates on stdout (the terminal, since command:run redirects only
# stderr); warn/die surface on the operator's console via the logger's
# preserved fd3 (ndh::logger:notice) so a failure isn't swallowed into the log
# sink — the full xtrace still lands in the log.
log() { printf '%s\n' ":: $*"; }
warn() { ndh::logger:notice "!! $*"; }
die() {
	ndh::logger:notice "xx $*"
	exit 1
}

usage() {
	cat <<'EOF'
Usage: manage-tailnet [options]   (run from the repo root)

Safe by default. Manages the per-kind Tailscale SaaS auth keys + the ACL.

  --dry-run          Show planned actions, change nothing (default).
  --rotate-auth-key  Mint fresh per-kind auth keys and write .secrets.
  --sync-acl         Reconcile the live tailnet ACL with our canonical fragment;
                     shows a diff.  POSTs only with --yes.
  --retag-devices    Reconcile each tailnet device's tags to its kind (from the
                     hostname); lists a plan, applies only with --yes.
  --prune-stale-devices
                     Delete TAGGED tailnet devices offline longer than
                     --stale-after — orphaned operator proxies from cold-start
                     teardowns that hold MagicDNS names (the funnel then drifts
                     to pac-webhook-1, -2, …).  Lists a plan; deletes only with
                     --yes.  Protects personal (untagged) + currently-online devices.
  --stale-after <dur>  Age threshold for --prune-stale-devices: Ns/Nm/Nh/Nd
                     (default 1h).
  --kind <kind>      Restrict rotation to a single kind (default: all).
  --deploy           Print the post-rotation rebuild commands (never runs them).
  --commit           After a successful rotation, git-commit .secrets (--no-verify).
  --revoke-old       Revoke the auth keys that existed before this run.
                     Requires --yes.  Runs only after new keys are written.
  --yes              Confirm destructive / remote-write actions (ACL POST, revoke).
  -h, --help         This help.
EOF
}

# Exchange the OAuth client secret for a short-lived API token, kept in the
# TOKEN global.  The client secret is decrypted straight into curl via a process
# substitution (curl reads /dev/fd/N) — no temp file, and it never hits an argv.
authenticate() {
	TOKEN="$($CURL -fsS \
		--data-urlencode client_secret@<($SOPS -d --input-type yaml --extract "$CLIENT_INDEX" "$SECRETS_FILE" 2>/dev/null) \
		"$API_BASE/oauth/token" | $YQ -p json '.access_token')" ||
		die "OAuth token exchange failed (bad/absent tailnet.tailscale.client, or network)"
	{ [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; } ||
		die "OAuth token exchange returned no access_token"
}

# Authenticated Tailscale API call.  The bearer is injected via a stdin config
# (heredoc) so the token never lands in a temp file or a process argument list.
# --fail-with-body: still fails (non-zero) on HTTP >=400 but emits the response
# body, so callers can surface the API's error message.
api() {
	$CURL --fail-with-body -sS --config - "$@" <<EOF
header = "Authorization: Bearer ${TOKEN}"
EOF
}

# Auth-key ids ONLY.  GET /keys also lists the OAuth client (keyType=client) and
# the admin API key (keyType=api); they must NEVER be revoked (revoking the
# client is self-destruction — it's the credential this tool authenticates
# with).  So the snapshot for --revoke-old is filtered to keyType=auth.
list_key_ids() {
	api "$API_BASE/tailnet/$TAILNET/keys" 2>/dev/null |
		$YQ -p json '.keys[] | select(.keyType == "auth") | .id' 2>/dev/null || true
}

revoke_key() {
	api -X DELETE "$API_BASE/tailnet/$TAILNET/keys/$1" >/dev/null 2>&1
}

# Reconcile the live tailnet ACL with @aclCanonical@.  Additive + rationalising:
# prune the superseded tags (operator/service/container) and the obsolete
# personal ones (work/committed/github — every host is owner-exclusive now),
# set our tag vocabulary + owners, replace acls/ssh with the role-based
# canonical, merge our route + exit-node auto-approvers; preserve the rest
# (k8s tagOwners, nodeAttrs, existing routes).
sync_acl() {
	# -o writes the body to a file (read twice below: reconcile + diff); -w emits
	# the ETag on stdout (captured) so we need no separate header dump file.
	local etag
	etag="$(api -o "$workdir/acl.cur.json" -w '%header{etag}' -H 'Accept: application/json' \
		"$API_BASE/tailnet/$TAILNET/acl")" || die "GET acl failed"

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

	# Review (diff) is the point of the dry-run; on --yes we just push (terse).
	if [ "$assume_yes" -ne 1 ]; then
		log "=== ACL reconcile diff (current -> target) ==="
		diff -u \
			<($YQ -p json -o=yaml '.' "$workdir/acl.cur.json") \
			<($YQ -p json -o=yaml '.' "$workdir/acl.target.json") || true
		log "NOTE: for minting to work, assign '$OWNER_TAG' to the rotation OAuth"
		log "      client in the Tailscale console (Settings -> OAuth clients)."
		log "no --yes: ACL not pushed.  Re-run 'manage-tailnet --sync-acl --yes' to POST."
		return 0
	fi

	log "pushing reconciled ACL (If-Match) …"
	local resp
	resp="$(api -X POST -H 'Content-Type: application/json' \
		${etag:+-H "If-Match: $etag"} --data-binary "@$workdir/acl.target.json" \
		"$API_BASE/tailnet/$TAILNET/acl")" ||
		die "POST acl rejected: $(printf '%s' "$resp" | $YQ -p json '.message // .' 2>/dev/null || printf '%s' "$resp")"
	log "SaaS ACL updated.  If not already done, assign '$OWNER_TAG' to the OAuth client (console)."
}

# Reconcile each tailnet device's tags to match its kind.  A tagged auth key only
# tags a device at REGISTRATION, so a node that registered before its per-kind
# key existed stays untagged; this heals the drift via POST /device/{id}/tags.
# Kind is derived from the hostname by convention: `<host>` = darwin (the bare
# Mac), `<host>-<kind>` = that kind (e.g. nikopol-nixos -> nixos).  Dry-run
# lists the plan; --yes applies.  Needs the OAuth client's `devices` scope.
retag_devices() {
	local devs
	devs="$(api "$API_BASE/tailnet/$TAILNET/devices")" ||
		die "GET devices failed (does the OAuth client have the 'devices' scope?)"
	mapfile -t rows < <(printf '%s' "$devs" |
		$YQ -p json -o=json -I=0 '.devices[] | {"id": .id, "host": .hostname, "tags": ((.tags // []) | sort)}')
	local row id host cur kind want spec k
	for row in "${rows[@]}"; do
		id="$(printf '%s' "$row" | $YQ -p json '.id')"
		host="$(printf '%s' "$row" | $YQ -p json '.host')"
		cur="$(printf '%s' "$row" | $YQ -p json -o=json -I=0 '.tags')"
		kind="darwin"
		for spec in "${specs[@]}"; do
			k="$(printf '%s' "$spec" | $YQ -p json '.kind')"
			[ "$k" = "darwin" ] && continue
			case "$host" in *-"$k")
				kind="$k"
				break
				;;
			esac
		done
		want="$(printf '%s\n' "${specs[@]}" |
			$YQ -p json -o=json -I=0 "select(.kind == \"$kind\") | (.tags | sort)" | head -n1)"
		if [ "$cur" = "$want" ]; then
			log "  $host: ok ($want)"
			continue
		fi
		if [ "$assume_yes" -ne 1 ]; then
			log "  $host: $cur -> $want  (kind=$kind)"
			continue
		fi
		api -X POST -H 'Content-Type: application/json' \
			-d "$(printf '%s' "$want" | $YQ -p json -o=json '{"tags": .}')" \
			"$API_BASE/device/$id/tags" >/dev/null || die "failed to set tags on $host ($id)"
		log "  $host: set $want"
	done
}

# Parse a simple duration (Ns/Nm/Nh/Nd; bare number = seconds) to seconds.
duration_seconds() {
	local d="$1" n unit
	n="${d%[smhd]}"
	unit="${d#"$n"}"
	printf '%s' "$n" | grep -qE '^[0-9]+$' || return 1
	case "$unit" in
	"" | s) printf '%s' "$n" ;;
	m) printf '%s' "$((n * 60))" ;;
	h) printf '%s' "$((n * 3600))" ;;
	d) printf '%s' "$((n * 86400))" ;;
	*) return 1 ;;
	esac
}

# An RFC3339 timestamp (device.lastSeen) -> unix epoch, portable across GNU and
# BSD date.  Prints 0 on an unparseable value so the caller skips it (never
# treats a parse failure as "very old" and deletes on it).
epoch_of() {
	local ts="${1%%.*}" # strip any fractional seconds
	ts="${ts%Z}"        # strip trailing Z (re-added for the GNU form)
	date -u -d "${ts}Z" +%s 2>/dev/null ||
		date -u -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null ||
		printf '0'
}

# Delete orphaned operator proxy devices — TAGGED devices whose lastSeen is older
# than --stale-after.  A cold start (the whole cluster re-created) never deletes
# its tailscale devices gracefully, so operator-created proxies (ingress funnels,
# Connectors) orphan in the tailnet and HOLD their MagicDNS names — the next grow
# can't reclaim `pac-webhook` and gets `pac-webhook-1`, accumulating stale hosts.
# The tag filter protects personal (untagged member) devices; the age filter
# protects the live cluster's currently-online devices.  Needs the OAuth client's
# `devices` scope (DELETE).  Dry-run lists the plan; --yes applies.
prune_stale_devices() {
	local threshold_s now devs
	threshold_s="$(duration_seconds "$stale_after")" || die "bad --stale-after: $stale_after"
	now="$(date +%s)"
	devs="$(api "$API_BASE/tailnet/$TAILNET/devices")" ||
		die "GET devices failed (does the OAuth client have the 'devices' scope?)"
	mapfile -t rows < <(printf '%s' "$devs" |
		$YQ -p json -o=json -I=0 '.devices[] | select((.tags // []) | length > 0) | {"id": .id, "host": .hostname, "seen": .lastSeen}')
	log "prune plan (tagged devices offline > $stale_after):"
	local row id host seen seen_s age n=0
	for row in "${rows[@]}"; do
		id="$(printf '%s' "$row" | $YQ -p json '.id')"
		host="$(printf '%s' "$row" | $YQ -p json '.host')"
		seen="$(printf '%s' "$row" | $YQ -p json '.seen')"
		seen_s="$(epoch_of "$seen")"
		[ "$seen_s" -gt 0 ] || {
			warn "  skip $host ($id): unparseable lastSeen ($seen)"
			continue
		}
		age=$((now - seen_s))
		[ "$age" -gt "$threshold_s" ] || continue
		n=$((n + 1))
		if [ "$assume_yes" -ne 1 ]; then
			log "  would delete $host ($id) — last seen $((age / 3600))h$(((age % 3600) / 60))m ago"
			continue
		fi
		if api -X DELETE "$API_BASE/device/$id" >/dev/null 2>&1; then
			log "  deleted $host ($id)"
		else
			warn "  failed to delete $host ($id)"
		fi
	done
	[ "$n" -gt 0 ] || log "  nothing to prune (no tagged device offline > $stale_after)"
	{ [ "$assume_yes" -eq 1 ] || [ "$n" -eq 0 ]; } ||
		log "no --yes: nothing deleted.  Re-run 'manage-tailnet --prune-stale-devices --yes' to apply."
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
# The key flows API-response -> yq -> sops stdin.  Appends the id to NEW_IDS.
mint_and_write() {
	local kind="$1" body="$2" resp index
	resp="$(api -H 'Content-Type: application/json' \
		-d "$body" "$API_BASE/tailnet/$TAILNET/keys" 2>/dev/null)" ||
		die "mint failed for kind=$kind (API error — check OAuth scope + ACL tagOwners)"
	printf '%s' "$resp" | $YQ -p json '.key' | grep -q '^tskey-auth-' ||
		die "mint for kind=$kind returned no/invalid key"
	index="[\"tailnet\"][\"tailscale\"][\"auth\"][\"$kind\"]"
	printf '%s' "$resp" | $YQ -p json -o=json '.key' |
		$SOPS set --input-type yaml --value-stdin "$SECRETS_FILE" "$index" ||
		die "sops write failed for kind=$kind"
	NEW_IDS+=("$(printf '%s' "$resp" | $YQ -p json '.id')")
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
	local oid nid skip
	for oid in "${OLD_IDS[@]}"; do
		[ -n "$oid" ] || continue
		skip=0
		for nid in "${NEW_IDS[@]}"; do [ "$oid" = "$nid" ] && {
			skip=1
			break
		}; done
		[ "$skip" -eq 1 ] && continue # never revoke one we just minted
		if revoke_key "$oid"; then log "  revoked $oid"; else warn "  failed to revoke $oid"; fi
	done
}

# Commit the (encrypted) .secrets after a successful rotation.  --no-verify: the
# commit only touches the sops blob — nothing treefmt/pre-commit governs — and
# must not be blocked by unrelated working-tree state.
commit_secrets() {
	$GIT add "$SECRETS_FILE" || die "git add $SECRETS_FILE failed"
	if $GIT diff --cached --quiet -- "$SECRETS_FILE"; then
		log "no .secrets change to commit"
		return 0
	fi
	$GIT commit --no-verify -m "chore(.secrets): rotate per-kind tailscale auth keys" >/dev/null ||
		die "git commit failed"
	log "committed $SECRETS_FILE"
}

specs=()
OLD_IDS=()
NEW_IDS=()

main() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--dry-run) dry_run=1 ;;
		--rotate-auth-key)
			do_auth=1
			dry_run=0
			;;
		--sync-acl) do_sync_acl=1 ;;
		--retag-devices) do_retag=1 ;;
		--prune-stale-devices) do_prune=1 ;;
		--stale-after)
			shift
			stale_after="${1:-}"
			[ -n "$stale_after" ] || die "--stale-after needs an argument"
			;;
		--kind)
			shift
			only_kind="${1:-}"
			[ -n "$only_kind" ] || die "--kind needs an argument"
			;;
		--deploy) do_deploy=1 ;;
		--revoke-old) do_revoke=1 ;;
		--commit) do_commit=1 ;;
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

	mapfile -t specs < <($YQ -p json -o=json -I=0 '.[]' "$AUTH_KINDS_FILE")

	log "controller: Tailscale SaaS"
	log "kinds: $($YQ -p json '[.[].kind] | join(", ")' "$AUTH_KINDS_FILE")${only_kind:+  (restricted to: $only_kind)}"

	authenticate

	[ "$do_sync_acl" -eq 1 ] && sync_acl
	[ "$do_retag" -eq 1 ] && retag_devices
	[ "$do_prune" -eq 1 ] && prune_stale_devices

	if [ "$do_auth" -eq 1 ]; then
		mapfile -t OLD_IDS < <(list_key_ids) # snapshot before minting (for --revoke-old)
		NEW_IDS=()
		rotate_auth
		[ "$do_commit" -eq 1 ] && commit_secrets
		[ "$do_revoke" -eq 1 ] && revoke_old
		if [ "$do_deploy" -eq 1 ]; then
			log "post-rotation deploy — run these yourself (this tool never mutates a live host):"
			log "  sudo nixos-rebuild switch --flake .#nikopol-nixos --refresh"
			log "  (repeat per host that consumes a rotated kind)"
		fi
	elif [ "$dry_run" -eq 1 ] && [ "$do_sync_acl" -eq 0 ] && [ "$do_retag" -eq 0 ] && [ "$do_prune" -eq 0 ]; then
		rotation_plan
	fi

	log "done."
}

ndh::logger:command:run "@loggerTag@" main "$@"
