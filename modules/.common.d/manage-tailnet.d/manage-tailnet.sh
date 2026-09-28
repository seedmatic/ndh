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
#                       show a diff, POST with If-Match only under --apply.
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
# matching flag (+ --apply for destructive/remote writes) is given.  Logging runs
# under ndh::logger:command:run (xtrace on) — the operator's private logs are
# the debug surface here.
source @nixBashTrampoline@

readonly SOPS="@sops@"
readonly CURL="@curl@"
readonly YQ="@yq@"
readonly GIT="@git@"
readonly AUTH_KINDS_FILE="@authKinds@"
export ACL_CANONICAL="@aclCanonical@" # exported so yq's load(strenv(...)) can read it
export SPLIT_DNS="@splitDns@"          # likewise, for --sync-dns
export SERVICES_CANONICAL="@servicesCanonical@" # likewise, for --sync-services

readonly API_BASE="https://api.tailscale.com/api/v2"
readonly TAILNET="-" # "-" = the OAuth identity's default tailnet
# Default: the repo's own blob, hence relative — this tool's home is a checkout.  NOT readonly,
# because --secrets-file redirects it to a copy carried by a caller that has NO checkout (the Tart
# materializer on a corp-managed vz-host bakes the ENCRYPTED blob into its bundle and decrypts it
# with the operator's age key).  Only the read path may be redirected; see the preflight.
SECRETS_FILE=".secrets"
readonly CLIENT_INDEX='["tailnet"]["tailscale"]["client"]'
readonly OWNER_TAG="tag:tailnet-key-owner"

# Option state (globals; set by main, read by helpers).
dry_run=1
do_auth=0
do_sync_acl=0
do_sync_dns=0
do_sync_services=0
do_retag=0
do_prune=0
do_reclaim=0
do_deploy=0
do_revoke=0
do_commit=0
assume_yes=0
stale_after="1h"
format="text"
only_kind=""
client_secret_file=""
secrets_file_override=0
workdir=""
# Hostnames --prune-stale-devices must SPARE even when stale: a device whose identity we PERSIST
# and RESTORE across a cold-start (a funnel proxy backed by a stable state Secret) must survive so
# the restored node key re-attaches to the SAME device (same MagicDNS name, cert reused) instead of
# re-registering. Only the drifted duplicates (pipelines-webhook-1, …) and un-persisted orphans are
# pruned. Exact-name match, repeatable via --keep-host.
keep_hosts=()
# Hostnames whose tailnet identity the caller is DESTROYING — see reclaim_host_names. Repeatable
# via --reclaim-host.
reclaim_hosts=()
TOKEN=""

# log() narrates on stdout (the terminal, since command:run redirects only
# stderr); warn/die surface on the operator's console via the logger's
# preserved fd3 (ndh::logger:notice) so a failure isn't swallowed into the log
# sink — the full xtrace still lands in the log.
#
# --format=json turns the whole of stdout into JSON Lines (one object per line):
# narration is not muzzled, it is STRUCTURED as {"level","msg"} events so a
# programmatic caller (rke2lab's in-cluster prune loop) can parse the stream
# while a human still reads it. yq's strenv encodes the message safely (no manual
# escaping). Only stdout is JSONL; the logger's fd3 is left to the text path.
log() {
	if [ "$format" = json ]; then
		msg="$*" $YQ -n -o=json -I=0 '{"level": "info", "msg": strenv(msg)}'
	else
		printf '%s\n' ":: $*"
	fi
}
warn() {
	if [ "$format" = json ]; then
		msg="$*" $YQ -n -o=json -I=0 '{"level": "warn", "msg": strenv(msg)}'
	else
		ndh::logger:notice "!! $*"
	fi
}
die() {
	if [ "$format" = json ]; then
		msg="$*" $YQ -n -o=json -I=0 '{"level": "error", "msg": strenv(msg)}'
	else
		ndh::logger:notice "xx $*"
	fi
	exit 1
}

usage() {
	cat <<'EOF'
Usage: manage-tailnet [options]   (run from the repo root)

Safe by default. Manages the per-kind Tailscale SaaS auth keys + the ACL.

  --dry-run          Show planned actions, change nothing (default).
  --rotate-auth-key  Mint fresh per-kind auth keys and write .secrets.
  --sync-acl         Reconcile the live tailnet ACL with our canonical fragment;
                     shows a diff.  POSTs only with --apply.
  --sync-dns         Reconcile the tailnet split-DNS map (each per-baremetal zone
                     -> that segment's dnsmasq) from the catalog; shows a diff.
                     PATCHes only with --apply.
  --sync-services    Reconcile the tailnet's Tailscale SERVICE definitions from
                     catalog.netplan.tailnet.services.  A service must EXIST before
                     any node may advertise it, so this runs BEFORE a host applies
                     its `serve set-config`.  Lists a plan; PUTs/DELETEs only with
                     --apply.  Prunes only services this tool owns (annotation
                     io.seedmatic.ndh/managed) — anything else is reported, kept.
  --retag-devices    Reconcile each tailnet device's tags to its kind (from the
                     hostname); lists a plan, applies only with --apply.
  --prune-stale-devices
                     Delete TAGGED tailnet devices offline longer than
                     --stale-after — orphaned operator proxies from cold-start
                     teardowns that hold MagicDNS names (the funnel then drifts
                     to pac-webhook-1, -2, …).  Lists a plan; deletes only with
                     --apply.  Protects personal (untagged) + currently-online devices.
  --reclaim-host <name>
                     Free ONE host's tailnet name: delete the TAGGED devices named
                     <name> or <name>-<N>, with NO age filter — the caller asserts
                     that host's identity is being DESTROYED (a nerd-nixos VM renew
                     recreates the ZFS root that carries /var/lib/tailscale), so the
                     re-registering host reclaims the bare name instead of drifting
                     to <name>-1.  Scoped, unlike --prune-stale-devices: it cannot
                     reach an itinerant host that is merely away.  Repeatable.
                     Lists a plan; deletes only with --apply.
  --stale-after <dur>  Age threshold for --prune-stale-devices: Ns/Nm/Nh/Nd
                     (default 1h).
  --keep-host <name>   Spare this EXACT hostname from --prune-stale-devices even
                     when stale (repeatable).  For a persisted funnel whose
                     identity is restored across a cold-start: keep it so the
                     restored node key re-attaches to the SAME device (name +
                     cert reused).  Drifted duplicates (name-1, name-2) do not
                     match the bare name, so they are still pruned.
  --format <fmt>     Output format: text (default) or json.  json emits JSON
                     Lines on stdout — every narration line as a {level,msg}
                     object, and each pruned device as a {event:"pruned",...}
                     object — so a caller can parse exactly what was removed.
  --client-secret-file <path>
                     Read the OAuth client secret from <path> (a bare
                     tskey-client-… scalar) instead of sops-decrypting .secrets
                     — lets a caller with no .secrets/age key (e.g. rke2lab's
                     incus GROW, reading ndh's user-mirrored client) drive the
                     read-only remote actions.  Incompatible with
                     --rotate-auth-key (which writes .secrets).
  --secrets-file <path>
                     Read the sops-encrypted .secrets from <path> instead of the
                     repo-relative default — for a caller with the operator's age
                     key but NO checkout (the Tart materializer bakes the encrypted
                     blob into its own bundle).  Read-only: incompatible with
                     --rotate-auth-key and --commit, which WRITE .secrets.
  --kind <kind>      Restrict rotation to a single kind (default: all).
  --deploy           Print the post-rotation rebuild commands (never runs them).
  --commit           After a successful rotation, git-commit .secrets (--no-verify).
  --revoke-old       Revoke the auth keys that existed before this run.
                     Requires --apply.  Runs only after new keys are written.
  --apply            Actually write: the remote-mutating half of every action above
                     (ACL POST, split-DNS PATCH, device retag/delete, key revoke).
                     Named for what it does, not for answering a prompt — nothing here
                     prompts, and every action is dry-run until this is passed.
  -h, --help         This help.
EOF
}

# Exchange the OAuth client secret for a short-lived API token, kept in the
# TOKEN global.  The client secret is decrypted straight into curl via a process
# substitution (curl reads /dev/fd/N) — no temp file, and it never hits an argv.
authenticate() {
	# The client secret reaches curl via /dev/fd/N (process substitution): either a
	# targeted sops extract of .secrets, or a caller-supplied plaintext file — never
	# a temp file, and never an argv.
	#
	# xtrace is MUTED for the whole function.  Keeping the secret out of argv and
	# passing the bearer through api()'s heredoc (heredoc bodies are NOT traced) are
	# both defeated one line later: the trampoline runs everything under `set -x`, so
	# the assignment below and each `[ … "$TOKEN" … ]` printed the bearer verbatim
	# into the operator's unified log — three times per run, measured.
	#
	# `local -` scopes the `set` options to this function, so the mute is undone on
	# return whatever the exit path — and it restores the CALLER's state rather than
	# re-asserting `set -x`, which would switch tracing on for a run that never had it
	# (the script is also runnable without the trampoline).
	local -
	set +x
	if [ -n "$client_secret_file" ]; then
		TOKEN="$($CURL -fsS \
			--data-urlencode "client_secret@$client_secret_file" \
			"$API_BASE/oauth/token" | $YQ -p json '.access_token')" ||
			die "OAuth token exchange failed (bad client-secret file, or network)"
	else
		TOKEN="$($CURL -fsS \
			--data-urlencode client_secret@<($SOPS -d --input-type yaml --extract "$CLIENT_INDEX" "$SECRETS_FILE" 2>/dev/null) \
			"$API_BASE/oauth/token" | $YQ -p json '.access_token')" ||
			die "OAuth token exchange failed (bad/absent tailnet.tailscale.client, or network)"
	fi
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
# prune the superseded tags (operator/service/container), the obsolete personal
# ones (work/committed/github — every host is owner-exclusive now) and the two
# kinds no device ever carried (incus/rke2), set our tag vocabulary + owners,
# replace grants/ssh/tests/autoApprovers with the role-based canonical; preserve the rest
# (nodeAttrs).
#
# ★ The `autogroup:members` -> `autogroup:member` rewrite is whole-document and NOT
# cosmetic: the control plane rejects a policy carrying both spellings — measured, "ACLs
# contain a mix of old-style autogroup:members and new-style autogroup:member; use one or
# the other."  So consistency is a property of the WHOLE file, which a canonical that only
# owns some fields cannot achieve alone.  The legacy spelling survives in `nodeAttrs`, a
# PRESERVED field carrying Tailscale's own Funnel/Taildrive defaults — semantically right,
# only spelled the old way.  Renaming the value in place is the narrowest fix available:
# the set is identical, and we take no ownership of what those attributes mean.  It
# rewrites VALUES only, never keys (verified against a document with a colliding key).
#
# ★ `autoApprovers` is REPLACED, not merged, and that was a defect for as long as it was
# merged.  An approver is the gate that turns someone's ADVERTISEMENT into an installed
# route on every accepting peer, so a key nobody governs is reach nobody reviews — and
# because a merge preserves live keys, dropping a CIDR from the catalog never withdrew
# it.  Measured 2026-09-27, the live map had accumulated five such orphans: the home LAN
# `192.168.1.0/24`, the pre-renumbering `172.16.6.0/24` and `172.16.7.0/24`, and two
# Connector-era `/32`s still approved for `tag:k8s` after that pod was removed.  None of
# them could ever have left.  Same reasoning as `acls` below: preservation is how
# withdrawn reach survives its own withdrawal.
#
# ★ `acls` is DELETED, not translated in place, and the deletion is load-bearing: the
# effective policy is the permissive UNION of `acls` and `grants`, so leaving the legacy
# block behind would keep granting whatever it still named.  That union was not
# hypothetical — measured 2026-09-27, an ungoverned `grants` block had been live
# alongside our `acls` all along, frozen on the pre-renumbering `172.16.6/7.0/24`.  This
# reconcile is what brings it under the catalog; setting one block without deleting the
# other is how reach survives its own withdrawal.
#
# It does NOT withdraw `192.168.1.0/24`: the canonical still grants the home LAN to
# `tag:console` while a bare-metal declares `lanAttachment = "fixed"`.  That grant is
# inert rather than wrong — nothing advertises the prefix since the outage, so no route
# exists to use it — and it is deliberately the hook for the scoped design described in
# the `lanCidrs` comment of default.nix.
#
# ★ `tests` is REPLACED like acls/ssh, and it is the safety gate rather than a
# nicety: the control plane refuses this POST outright when an assertion fails, so
# a reach-widening edit cannot land silently.  Keep it replaced, never merged — a
# stale assertion kept from the live policy would either block a deliberate change
# or, worse, pass while asserting a shape we no longer intend.
#
# `tag:k8s` OWNERSHIP is deliberately preserved, never asserted: it is the
# Tailscale operator chart's default tag, claimed by the operator's OAuth client.
# Adding it to our vocabulary would make the canonical tagOwners overwrite that
# claim — the merge is `live * canonical` — and the operator would stop being
# able to register any device.  The canonical `grants` names it as a dst instead,
# which needs no ownership.
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
        | del(.["tag:work"]) | del(.["tag:committed"]) | del(.["tag:github"])
        | del(.["tag:incus"]) | del(.["tag:rke2"]))
      * load(strenv(ACL_CANONICAL)).tagOwners)
    | .grants = load(strenv(ACL_CANONICAL)).grants
    | del(.acls)
    | .ssh  = load(strenv(ACL_CANONICAL)).ssh
    | .tests = load(strenv(ACL_CANONICAL)).tests
    | .autoApprovers = load(strenv(ACL_CANONICAL)).autoApprovers
    | (.. | select(. == "autogroup:members")) |= "autogroup:member"
  ' "$workdir/acl.cur.json" >"$workdir/acl.target.json" || die "ACL reconcile failed"

	# Shown on BOTH paths, and on --apply BEFORE the POST. The dry-run's diff is not evidence of what
	# an apply changes: they are two separate GETs, so the reviewed document and the pushed one are
	# only presumed identical (`If-Match` REJECTS a concurrent edit, which protects the write but says
	# nothing about what this run altered). Printing it here is what leaves a record of the act, for a
	# document that governs the whole fleet's authorization — and both files are already in hand, so
	# it costs a diff.
	log "=== ACL reconcile diff (current -> target) ==="
	diff -u \
		<($YQ -p json -o=yaml '.' "$workdir/acl.cur.json") \
		<($YQ -p json -o=yaml '.' "$workdir/acl.target.json") || true

	if [ "$assume_yes" -ne 1 ]; then
		log "NOTE: for minting to work, assign '$OWNER_TAG' to the rotation OAuth"
		log "      client in the Tailscale console (Settings -> OAuth clients)."
		log "no --apply: ACL not pushed.  Re-run 'manage-tailnet --sync-acl --apply' to POST."
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

# Reconcile the tailnet SPLIT-DNS map with the catalog: each per-baremetal zone resolved by that
# segment's own Incus dnsmasq.
#
# This closes the last tailnet fact that was not in git. Its absence is what let the map keep
# pointing at a retired resolver through the 2026-09-23 fabric renumbering, while the two
# GENERATED consumers of the same `netGateway` corrected themselves at the next rebuild.
#
# PATCH /dns/split-dns merges SERVER-SIDE — "only domains specified in the request map will be
# modified", and a null value clears one. So we send only OUR map and a zone we do not declare is
# left alone (someone may have added one for a reason this catalog does not know). The GET is for
# the DIFF alone, not to build the payload; and no If-Match, which this endpoint does not document.
sync_dns() {
	api -o "$workdir/dns.cur.json" -H 'Accept: application/json' \
		"$API_BASE/tailnet/$TAILNET/dns/split-dns" >/dev/null || die "GET split-dns failed"

	if [ "$assume_yes" -ne 1 ]; then
		# Diffed as JSON, sorted: it is the wire format this PATCHes, so the diff shows exactly
		# what would be sent rather than a transcription of it. (It was YAML on both sides at
		# first, which read badly — yq inherits the FLOW style of the JSON document it loads, so
		# the target came out on one line against a block-style current.)
		log "=== split-DNS reconcile diff (current -> target) ==="
		diff -u \
			<($YQ -p json -o=json -P 'sort_keys(..)' "$workdir/dns.cur.json") \
			<($YQ -p json -o=json -P '(. * load(strenv(SPLIT_DNS))) | sort_keys(..)' "$workdir/dns.cur.json") || true
		log "no --apply: split-DNS not pushed.  Re-run 'manage-tailnet --sync-dns --apply' to PATCH."
		return 0
	fi

	log "patching split-DNS …"
	local resp
	resp="$(api -X PATCH -H 'Content-Type: application/json' \
		--data-binary "@$SPLIT_DNS" \
		"$API_BASE/tailnet/$TAILNET/dns/split-dns")" ||
		die "PATCH split-dns rejected: $(printf '%s' "$resp" | $YQ -p json '.message // .' 2>/dev/null || printf '%s' "$resp")"
	log "split-DNS pushed."
}

# Reconcile the tailnet's Tailscale SERVICE definitions with @servicesCanonical@.
#
# Ordering is a hard dependency, not a preference: a service must EXIST here before any
# node may advertise it with `serve set-config`, and an advertisement of an undefined (or
# unapproved) service is INERT — tailscaled returns early with "No approved VIP Services"
# rather than failing, so the symptom of getting this order wrong is silence.
#
# ★ Live object FIRST, ours merged on top.  Tailscale AUTO-ALLOCATES the `addrs` pair when
# a service is created, and the vendor's own client warns that a later update omitting them
# ERRORS — so the merge is what carries them forward.  Writing the catalog's object
# verbatim would work exactly once, then break on every subsequent run.
#
# Pruning is scoped by OWNERSHIP (the io.seedmatic.ndh/managed annotation) rather than by
# "not in the catalog".  The tailscale k8s-operator can create services of its own, and the
# rule this repo learned the hard way today is that a field nobody governs is state nobody
# reviews — so we govern what we marked, and report the rest instead of deleting it.
sync_services() {
	api -o "$workdir/svc.cur.json" -H 'Accept: application/json' \
		"$API_BASE/tailnet/$TAILNET/vip-services" >/dev/null || die "GET vip-services failed"

	local count i name want_file cur_file target_file changes=0
	count="$($YQ -p json 'length' "$SERVICES_CANONICAL")"

	log "=== Tailscale Services reconcile plan ==="

	i=0
	while [ "$i" -lt "$count" ]; do
		want_file="$workdir/svc.want.$i.json"
		I="$i" $YQ -p json -o=json '.[env(I)]' "$SERVICES_CANONICAL" >"$want_file"
		name="$($YQ -p json '.name' "$want_file")"

		cur_file="$workdir/svc.cur.$i.json"
		SVC_NAME="$name" $YQ -p json -o=json \
			'[.vipServices[] | select(.name == strenv(SVC_NAME))] | .[0] // {}' \
			"$workdir/svc.cur.json" >"$cur_file"

		target_file="$workdir/svc.target.$i.json"
		WANT="$want_file" $YQ -p json -o=json '. * load(strenv(WANT))' "$cur_file" >"$target_file"

		if [ "$($YQ -p json 'length' "$cur_file")" -eq 0 ]; then
			log "  CREATE $name  ports=$($YQ -p json -o=json -I0 '.ports' "$want_file")"
			changes=$((changes + 1))
		elif ! diff -q \
			<($YQ -p json -o=json -P 'sort_keys(..)' "$cur_file") \
			<($YQ -p json -o=json -P 'sort_keys(..)' "$target_file") >/dev/null; then
			log "  UPDATE $name"
			diff -u \
				<($YQ -p json -o=json -P 'sort_keys(..)' "$cur_file") \
				<($YQ -p json -o=json -P 'sort_keys(..)' "$target_file") || true
			changes=$((changes + 1))
		else
			log "  unchanged $name"
		fi
		i=$((i + 1))
	done

	# Ours-but-gone, versus someone else's.  The annotation is the discriminator.
	local stale foreign
	stale="$(DESIRED="$SERVICES_CANONICAL" $YQ -p json -o=csv -I0 '
		[ .vipServices[]
		  | select(.annotations["io.seedmatic.ndh/managed"] == "true")
		  | select([.name] - [load(strenv(DESIRED))[].name] | length > 0)
		  | .name ]' "$workdir/svc.cur.json")" || stale=""
	foreign="$($YQ -p json -o=csv -I0 '
		[ .vipServices[]
		  | select(.annotations["io.seedmatic.ndh/managed"] != "true")
		  | .name ]' "$workdir/svc.cur.json")" || foreign=""
	[ -n "$stale" ] && {
		log "  DELETE (ours, no longer in the catalog): $stale"
		changes=$((changes + 1))
	}
	[ -n "$foreign" ] && log "  KEEP (not ours, left alone): $foreign"

	if [ "$assume_yes" -ne 1 ]; then
		log "no --apply: $changes change(s) NOT pushed.  Re-run 'manage-tailnet --sync-services --apply'."
		return 0
	fi

	i=0
	while [ "$i" -lt "$count" ]; do
		name="$($YQ -p json '.name' "$workdir/svc.want.$i.json")"
		log "PUT $name …"
		local resp
		resp="$(api -X PUT -H 'Content-Type: application/json' \
			--data-binary "@$workdir/svc.target.$i.json" \
			"$API_BASE/tailnet/$TAILNET/vip-services/$name")" ||
			die "PUT $name rejected: $(printf '%s' "$resp" | $YQ -p json '.message // .' 2>/dev/null || printf '%s' "$resp")"
		i=$((i + 1))
	done

	local old_ifs
	old_ifs="$IFS"
	IFS=','
	for name in $stale; do
		[ -n "$name" ] || continue
		log "DELETE $name …"
		api -X DELETE "$API_BASE/tailnet/$TAILNET/vip-services/$name" >/dev/null ||
			die "DELETE $name failed"
	done
	IFS="$old_ifs"

	log "Tailscale Services reconciled."
}

# Reconcile each tailnet device's tags to match its kind.  A tagged auth key only
# tags a device at REGISTRATION, so a node that registered before its per-kind
# key existed stays untagged; this heals the drift via POST /device/{id}/tags.
# Kind is derived from the hostname by convention: `<host>` = darwin (the bare
# Mac), `<host>-<kind>` = that kind (e.g. nikopol-nixos -> nixos).  Dry-run
# lists the plan; --apply applies.  Needs the OAuth client's `devices` scope.
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
# `devices` scope (DELETE).  Dry-run lists the plan; --apply applies.
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
		# Spare a persisted device by EXACT hostname (--keep-host): its identity is restored across a
		# cold-start, so it must survive to re-attach.  A drifted duplicate (host-1, host-2) does not
		# match the bare name, so it is still pruned — the reclaim we actually want.
		if [ "${#keep_hosts[@]}" -gt 0 ]; then
			local keep
			for keep in "${keep_hosts[@]}"; do
				if [ "$host" = "$keep" ]; then
					log "  keep $host ($id): persisted device (--keep-host)"
					continue 2
				fi
			done
		fi
		age=$((now - seen_s))
		[ "$age" -gt "$threshold_s" ] || continue
		n=$((n + 1))
		if [ "$assume_yes" -ne 1 ]; then
			log "  would delete $host ($id) — last seen $((age / 3600))h$(((age % 3600) / 60))m ago"
			continue
		fi
		if api -X DELETE "$API_BASE/device/$id" >/dev/null 2>&1; then
			if [ "$format" = json ]; then
				# A structured event (distinct from the {level,msg} narration) so a caller
				# selects `.event == "pruned"` to learn exactly which devices were removed.
				id="$id" host="$host" seen="$seen" $YQ -n -o=json -I=0 \
					'{"level": "info", "event": "pruned", "id": strenv(id), "host": strenv(host), "seen": strenv(seen)}'
			else
				log "  deleted $host ($id)"
			fi
		else
			warn "  failed to delete $host ($id)"
		fi
	done
	[ "$n" -gt 0 ] || log "  nothing to prune (no tagged device offline > $stale_after)"
	{ [ "$assume_yes" -eq 1 ] || [ "$n" -eq 0 ]; } ||
		log "no --apply: nothing deleted.  Re-run 'manage-tailnet --prune-stale-devices --apply' to apply."
}

# Free ONE host's tailnet name, because the caller is about to destroy that host's identity —
# a `nerd-nixos` VM renew recreates tank/nerd/root, and /var/lib/tailscale lives there, so the
# node key does not survive.  Deletes the TAGGED devices named <host> or <host>-<N>, so the
# re-registering host reclaims the bare name instead of drifting to <host>-1.  Repeatable.
#
# ★ DELIBERATELY NO AGE FILTER, and that is the whole difference from --prune-stale-devices.
#   - Correctness: at renew the host's own device is often still ONLINE (the VM has not been shut
#     down yet), so an age filter would SPARE exactly the device whose name we need, and the drift
#     would happen anyway.  Tailscale also only marks a node offline after its ~50s keepalive
#     window, which is why the in-cluster purge Job needs a 90s guard loop to converge.  Asserting
#     "this identity is being destroyed" removes the race instead of waiting it out.
#   - Safety: this is the SCOPED counterpart of a fleet-wide action.  --prune-stale-devices walks
#     every tagged device, so an ITINERANT host that is merely away (nikopol off the tailnet, its
#     device legitimately offline) is in its blast radius; this walks only the names the caller
#     names, so it cannot reach another host.  Untagged (personal) devices are skipped here too —
#     the same guard, since a member device must never be deletable by fleet tooling.
reclaim_host_names() {
	local devs
	devs="$(api "$API_BASE/tailnet/$TAILNET/devices")" ||
		die "GET devices failed (does the OAuth client have the 'devices' scope?)"
	mapfile -t rows < <(printf '%s' "$devs" |
		$YQ -p json -o=json -I=0 '.devices[] | select((.tags // []) | length > 0) | {"id": .id, "host": .hostname, "seen": .lastSeen}')
	log "reclaim plan (tagged devices holding: ${reclaim_hosts[*]}):"
	local row id host seen name suffix matched n=0
	for row in "${rows[@]}"; do
		id="$(printf '%s' "$row" | $YQ -p json '.id')"
		host="$(printf '%s' "$row" | $YQ -p json '.host')"
		seen="$(printf '%s' "$row" | $YQ -p json '.seen')"
		matched=""
		for name in "${reclaim_hosts[@]}"; do
			case "$host" in
				"$name")
					matched="$name"
					;;
				"$name"-*)
					# Only a NUMERIC suffix is this name's drift: `bioskop-nixos-1` is the duplicate
					# tailscale minted, while `bioskop-nixos-something` would be a different host.
					suffix="${host##*-}"
					case "$suffix" in
						'' | *[!0-9]*) ;;
						*) matched="$name" ;;
					esac
					;;
			esac
			[ -n "$matched" ] && break
		done
		[ -n "$matched" ] || continue
		n=$((n + 1))
		if [ "$assume_yes" -ne 1 ]; then
			log "  would delete $host ($id) — holds '$matched', last seen $seen"
			continue
		fi
		if api -X DELETE "$API_BASE/device/$id" >/dev/null 2>&1; then
			if [ "$format" = json ]; then
				id="$id" host="$host" seen="$seen" $YQ -n -o=json -I=0 \
					'{"level": "info", "event": "reclaimed", "id": strenv(id), "host": strenv(host), "seen": strenv(seen)}'
			else
				log "  deleted $host ($id)"
			fi
		else
			die "failed to delete $host ($id) — the name stays held and the host WILL drift to ${host}-N"
		fi
	done
	[ "$n" -gt 0 ] || log "  nothing to reclaim (no tagged device holds those names)"
	{ [ "$assume_yes" -eq 1 ] || [ "$n" -eq 0 ]; } ||
		log "no --apply: nothing deleted.  Re-run with --apply to free the name."
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
	log "Actions: --rotate-auth-key (mint + write; --revoke-old --apply to retire old);"
	log "         --sync-acl (review/reconcile the tailnet ACL; --sync-acl --apply to push)."
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
		die "--revoke-old requires --apply (destructive: revokes pre-existing auth keys)"
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
		--sync-dns) do_sync_dns=1 ;;
		--sync-services) do_sync_services=1 ;;
		--retag-devices) do_retag=1 ;;
		--prune-stale-devices) do_prune=1 ;;
		--stale-after)
			shift
			stale_after="${1:-}"
			[ -n "$stale_after" ] || die "--stale-after needs an argument"
			;;
		--keep-host)
			shift
			[ -n "${1:-}" ] || die "--keep-host needs an argument"
			keep_hosts+=("$1")
			;;
		--reclaim-host)
			shift
			[ -n "${1:-}" ] || die "--reclaim-host needs an argument"
			reclaim_hosts+=("$1")
			do_reclaim=1
			;;
		--secrets-file)
			shift
			SECRETS_FILE="${1:-}"
			[ -n "$SECRETS_FILE" ] || die "--secrets-file needs an argument"
			secrets_file_override=1
			;;
		--format=*) format="${1#*=}" ;;
		--format)
			shift
			format="${1:-}"
			[ -n "$format" ] || die "--format needs an argument"
			;;
		--kind)
			shift
			only_kind="${1:-}"
			[ -n "$only_kind" ] || die "--kind needs an argument"
			;;
		--client-secret-file)
			shift
			client_secret_file="${1:-}"
			[ -n "$client_secret_file" ] || die "--client-secret-file needs an argument"
			;;
		--deploy) do_deploy=1 ;;
		--revoke-old) do_revoke=1 ;;
		--commit) do_commit=1 ;;
		--apply) assume_yes=1 ;;
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
	[ "$format" = text ] || [ "$format" = json ] ||
		die "--format must be 'text' or 'json' (got: $format)"
	[ -r "$AUTH_KINDS_FILE" ] || die "kinds manifest missing: $AUTH_KINDS_FILE"
	# A read-only build leaves git unpinned to keep its closure small (see default.nix `withCommit`).
	{ [ "$do_commit" -eq 0 ] || [ -n "$GIT" ]; } ||
		die "this build of manage-tailnet excludes git, so --commit is unavailable; run it from a checkout"
	[ -r "$ACL_CANONICAL" ] || die "acl canonical missing: $ACL_CANONICAL"
	if [ -n "$client_secret_file" ]; then
		# Caller supplies the OAuth client secret directly — .secrets is neither read
		# nor written, so its checks are skipped.  It is a READ path only: minting
		# rotates keys INTO .secrets, which we are not touching here.
		[ -r "$client_secret_file" ] || die "client-secret file not readable: $client_secret_file"
		[ "$do_auth" -eq 0 ] || die "--client-secret-file is incompatible with --rotate-auth-key (which writes .secrets)"
	else
		# A redirected blob is a READ path only: the store copy is immutable, and `git add` on a
		# store path is meaningless — so refuse the two actions that write, rather than fail
		# halfway through a rotation.
		if [ "$secrets_file_override" -eq 1 ]; then
			[ "$do_auth" -eq 0 ] || die "--secrets-file is incompatible with --rotate-auth-key (which writes .secrets)"
			[ "$do_commit" -eq 0 ] || die "--secrets-file is incompatible with --commit (which git-adds .secrets)"
			[ -f "$SECRETS_FILE" ] || die "--secrets-file not found: $SECRETS_FILE"
		else
			[ -f "$SECRETS_FILE" ] || die "run from the repo root: $SECRETS_FILE not found"
		fi
		local sops_version
		sops_version="$($YQ '.sops.version' "$SECRETS_FILE" 2>/dev/null || true)"
		{ [ -n "$sops_version" ] && [ "$sops_version" != "null" ]; } ||
			die "$SECRETS_FILE is not sops-encrypted at rest (no .sops metadata); refusing"
	fi

	umask 077
	workdir="$(mktemp -d "${TMPDIR:-/tmp}/rotate-tailnet.XXXXXX")"
	trap 'rm -rf "$workdir"' EXIT INT TERM

	mapfile -t specs < <($YQ -p json -o=json -I=0 '.[]' "$AUTH_KINDS_FILE")

	log "controller: Tailscale SaaS"
	log "kinds: $($YQ -p json '[.[].kind] | join(", ")' "$AUTH_KINDS_FILE")${only_kind:+  (restricted to: $only_kind)}"

	authenticate

	[ "$do_sync_acl" -eq 1 ] && sync_acl
	[ "$do_sync_dns" -eq 1 ] && sync_dns
	[ "$do_sync_services" -eq 1 ] && sync_services
	[ "$do_retag" -eq 1 ] && retag_devices
	[ "$do_prune" -eq 1 ] && prune_stale_devices
	[ "$do_reclaim" -eq 1 ] && reclaim_host_names

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
	elif [ "$dry_run" -eq 1 ] && [ "$do_sync_acl" -eq 0 ] && [ "$do_sync_dns" -eq 0 ] && [ "$do_sync_services" -eq 0 ] && [ "$do_retag" -eq 0 ] && [ "$do_prune" -eq 0 ] && [ "$do_reclaim" -eq 0 ]; then
		rotation_plan
	fi

	log "done."
}

# When JSON output is requested, run WITHOUT the logger trampoline: its command:starting/marker
# announce (and the xtrace it enables) interleave non-JSON lines into stdout, which breaks a caller
# parsing the JSON Lines. json mode is the machine path — the JSONL stream IS the log, and log()/
# warn()/die() emit it directly (no logger dependency) — so the operator-facing trampoline is not
# wanted there. Any other invocation keeps the trampoline (private xtrace log + markers).
want_json=0
prev=""
for arg in "$@"; do
	case "$arg" in
	--format=json) want_json=1 ;;
	json) [ "$prev" = --format ] && want_json=1 ;;
	esac
	prev="$arg"
done
if [ "$want_json" -eq 1 ]; then
	main "$@"
else
	ndh::logger:command:run "@loggerTag@" main "$@"
fi
