#!/usr/bin/env -S bash -euo pipefail
# incus-cluster-join — join one itinerant member to the Incus cluster whose bootstrap member is the
# sedentary bare-metal.  An OPERATOR app, deliberately, and not a unit on the joining host.
#
# Why an operator act.  A join token is single-use and expires (cluster.join_token_expiry, which this
# fleet narrows to the same short window it uses for trust tokens), with no documented alternative for
# a non-interactive join.  Baking one into an image would start it ageing before the VM boots and make
# that image good for exactly one join inside one window — a single-use credential in the wrong
# lifecycle.  So it is minted and consumed in the same breath, here, over access the operator already
# has.  The alternative (a unit on the joining member fetching its own token over a bounded
# capability) answers a question that need not be asked: a join happens ONCE per member, and that
# member is materialised by an operator command anyway, so autonomy buys nothing while costing a
# distributed keypair and a standing right to invite members.
#
# Base: the shared bash trampoline (nix-managed bash + logger + stable env), like the other operator
# apps.  ssh and timeout are pinned by store path because the trampoline owns PATH.
#
# Build-time tokens (pkgs.replaceVars), written WITHOUT at-sigils so replaceVars does not substitute
# them in this comment: nixBashTrampoline, loggerTag, ssh, timeout, jq, yq, joiningMember,
# bootstrapMember, joiningSsh, bootstrapSsh, poolName, poolSource.
#
# Usage: <host>-incus-cluster-join [--dry-run]
source @nixBashTrampoline@

readonly JOINING="@joiningMember@"
readonly BOOTSTRAP="@bootstrapMember@"
readonly JOINING_SSH="@joiningSsh@"
readonly BOOTSTRAP_SSH="@bootstrapSsh@"
readonly POOL_NAME="@poolName@"
readonly POOL_SOURCE="@poolSource@"

# Every remote call goes through here so the ssh options are stated once. ConnectTimeout does not
# cover NAME RESOLUTION, so the hard timeout wraps it — the lesson the baremetal-link deploy learned
# when a segment's resolver moved and a 5s ConnectTimeout hung for 30.
remote() {
	local target="$1"
	shift
	@timeout@ 60 @ssh@ -o ConnectTimeout=10 -o BatchMode=yes "$target" -- "$@"
}

# Parse the STRUCTURE, not the text.  Measured 2026-09-26: incus emits
# `"server_clustered": true,` WITH a space, so a `grep '"server_clustered":true'` never matches —
# and its failure mode was the worst kind, reporting "bioskop-nixos is not a cluster yet" about a
# cluster that was live and Fully operational.  Same form as modules/nixos/incus-cluster.nix.
is_clustered() {
	remote "$1" incus query /1.0 2>/dev/null |
		@jq@ -e '.environment.server_clustered == true' >/dev/null 2>&1
}

main() {
	local dry_run=false
	[[ "${1:-}" == --dry-run ]] && dry_run=true

	ndh::logger:notice "join: ${JOINING} -> cluster of ${BOOTSTRAP}"

	# Idempotence, and it must be checked on the JOINING side: `incus admin init` on an
	# already-clustered daemon is an error, and re-minting a token for an existing member is worse
	# than useless — it leaves a live credential behind.
	if is_clustered "${JOINING_SSH}"; then
		ndh::logger:notice "join: ${JOINING} is already a cluster member — nothing to do"
		return 0
	fi

	if ! is_clustered "${BOOTSTRAP_SSH}"; then
		ndh::logger:error "join: ${BOOTSTRAP} is not a cluster yet — its incus-cluster-bootstrap unit has not run"
		return 1
	fi

	# The joining member's own address for cluster traffic, read where it lives rather than restated:
	# it is a tailnet address, assigned by the control plane, so it is not a build-time fact. And it
	# CHANGES when that VM is renewed, which is why nothing may cache it.
	local member_address
	member_address="$(remote "${JOINING_SSH}" ip -4 -o addr show tailscale0 |
		awk '{print $4}' | cut -d/ -f1)"
	if [[ -z "${member_address}" ]]; then
		ndh::logger:error "join: ${JOINING} carries no IPv4 on tailscale0 — is it on the tailnet?"
		return 1
	fi

	local cluster_address
	cluster_address="$(remote "${BOOTSTRAP_SSH}" incus config get cluster.https_address)"
	if [[ -z "${cluster_address}" ]]; then
		ndh::logger:error "join: ${BOOTSTRAP} has no cluster.https_address"
		return 1
	fi

	if "${dry_run}"; then
		ndh::logger:notice "join: --dry-run — would join ${member_address}:8443 to ${cluster_address}"
		return 0
	fi

	# Mint. `--quiet` drops the progress chatter; the token is the last non-empty line. The shape is
	# NOT assumed beyond "long and on its own line" — a short answer means the CLI changed its output
	# and we refuse rather than feed rubbish into a preseed.
	local token
	token="$(remote "${BOOTSTRAP_SSH}" incus cluster add --quiet "${JOINING}" |
		grep -v '^[[:space:]]*$' | tail -1 | tr -d '[:space:]')"
	if ((${#token} < 32)); then
		ndh::logger:error "join: no join token in the output of 'incus cluster add ${JOINING}'"
		return 1
	fi
	ndh::logger:notice "join: token minted (${#token} chars), consuming it now"

	# Consume. `member_config` carries the one thing that IS member-specific here: this member's
	# storage-pool source. Networks need no member_config at all — none are Incus-managed any more,
	# which is what let the per-host subnets survive clustering in the first place.
	#
	# ★ EVERY mutating step below is checked explicitly, and `set -e` is NOT relied on.  Measured
	# 2026-09-26, the hard way: ndh::logger:command:run invokes `main` as `if "$@"; then`, and POSIX
	# suppresses errexit throughout a command that forms a condition — re-running `set -e` inside
	# changes nothing.  So every unchecked command in a logger-wrapped script fails SILENTLY.  This
	# app reported "joined and out of the raft" about a join that never happened, on a cluster whose
	# member list still had one entry.
	local preseed preseed_out
	preseed="$(
		cat <<-EOF
			cluster:
			  enabled: true
			  server_name: ${JOINING}
			  server_address: ${member_address}:8443
			  cluster_address: ${cluster_address}
			  cluster_token: ${token}
			  member_config:
			  - entity: storage-pool
			    name: ${POOL_NAME}
			    key: source
			    value: ${POOL_SOURCE}
		EOF
	)"
	if ! preseed_out="$(printf '%s\n' "${preseed}" |
		remote "${JOINING_SSH}" incus admin init --preseed 2>&1)"; then
		ndh::logger:error "join: ${JOINING} REFUSED the preseed — it is not a member, and the token is now spent"
		printf '%s\n' "${preseed_out}" >&2
		return 1
	fi

	# ★ Demote IMMEDIATELY, and this is not cosmetic. Until the role is applied, a two-member cluster
	# has TWO voters (cluster.max_voters must be odd >= 3 and cannot be lowered), so the majority is 2
	# and this itinerant member leaving would take the SEDENTARY member's database down with it. The
	# host that carries every live cluster. The declarative reconciler on the bootstrap member also
	# asserts this, but only at its next activation — that window is exactly what this closes.
	ndh::logger:notice "join: pinning ${JOINING} out of the raft (database-client)"
	if ! remote "${BOOTSTRAP_SSH}" incus cluster role add "${JOINING}" database-client; then
		ndh::logger:error "join: could not give ${JOINING} the database-client role — it may be a VOTER"
		return 1
	fi

	# Verify what is PRESENT, never what is absent.  The previous version asserted that `roles` did
	# not contain `database` — which passes when `incus cluster show` fails and `roles` is EMPTY.  An
	# assertion that succeeds on missing input is not an assertion; it is how this app came to report
	# success about nothing.  So: the joining side must say it is clustered, the bootstrap side must
	# know the member, and the role must be THERE.
	if ! is_clustered "${JOINING_SSH}"; then
		ndh::logger:error "join: ${JOINING} still reports itself standalone — the join did not take"
		return 1
	fi

	local roles
	if ! roles="$(remote "${BOOTSTRAP_SSH}" incus cluster show "${JOINING}" | @yq@ -r '.roles | join(",")')"; then
		ndh::logger:error "join: ${BOOTSTRAP} knows no member named ${JOINING} — the join did not take"
		return 1
	fi
	case ",${roles}," in
		*,database-client,*) ;;
		*)
			ndh::logger:error "join: ${JOINING} is a member but NOT database-client (roles: ${roles:-<none>})."
			ndh::logger:error "join: its absence would cost ${BOOTSTRAP} its quorum — refusing to report success"
			return 1
			;;
	esac

	ndh::logger:notice "join: ${JOINING} joined and out of the raft (roles: ${roles})"
	remote "${BOOTSTRAP_SSH}" incus cluster list
}

ndh::logger:command:run "@loggerTag@" main "$@"
