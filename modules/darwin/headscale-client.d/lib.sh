# Shared helpers for the Darwin headscale-client module.
#
# Functions form a small API surface called from each consumer's main();
# the per-function lint-disable directives below silence the "function
# never invoked" check (SC2329) on helpers reached only through the
# indirect chain via ndh::headscaleClient:reconcile.
#
# Sourced inline (via pkgs.replaceVars and the HEADSCALE_CLIENT_LIB_INLINE
# substitution token) into both consumers of the headscale-client logic:
#
#   modules/darwin/headscale-client.d/post-activation.sh
#   the `hs-connect` wrapper produced by modules/darwin/headscale.nix
#
# Inlined-source rather than `source path/lib.sh` because writeShellApplication
# runs shellcheck over the whole composed script at build time, and shellcheck
# can't follow dynamic / store-path source statements (SC1091).  Inlining
# keeps the lint pass intact.
#
# All functions are namespaced under `ndh::headscaleClient:` to make
# the call sites unambiguous when both this lib and the trampoline's
# `ndh::logger:*` family live in the same script.
#
# Contract: the trampoline (@nixBashTrampoline@) MUST be sourced
# before this lib.  The trampoline brings in the logger framework
# and re-execs under a Nix-managed bash; functions here assume
# Bash 5+ and `pipefail`.

# Read tailscale's persisted prefs and surface the operator-intent
# bit `LoggedOut`.  Echoes "true" or "false"; empty if the LocalAPI
# is unreachable (e.g. tailscaled isn't running yet).
# shellcheck disable=SC2329
ndh::headscaleClient:prefsLoggedOut() {
	tailscale debug prefs 2>/dev/null \
		| sed -n 's/.*"LoggedOut": *\(true\|false\).*/\1/p' \
		| head -n1
}

# Poll `tailscale status --json` until BackendState reaches one of
# the terminal states (Running, NeedsLogin) or we exhaust the retry
# budget.  Echoes the last-observed BackendState on stdout; empty
# if the LocalAPI is unreachable for the whole window.
#
# Bounded retry covers the transient case where launchd has just
# kicked tailscaled (e.g. binary swap during darwin-rebuild switch)
# and the daemon hasn't finished reconnecting to the control plane.
#
# Args: <max-retries> <sleep-seconds-between-retries>
# shellcheck disable=SC2329
ndh::headscaleClient:waitBackendState() {
	local maxRetries="$1"
	local sleepSeconds="$2"
	local i state=""

	for ((i = 0; i < maxRetries; i++)); do
		state="$(tailscale status --json 2>/dev/null \
			| sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' \
			| head -n1)"
		case "$state" in
			Running|NeedsLogin)
				printf '%s\n' "$state"
				return 0
				;;
		esac
		if (( i < maxRetries - 1 )); then
			sleep "$sleepSeconds"
		fi
	done
	printf '%s\n' "$state"
}

# Logout-then-up flow with --reset and a sops-materialised auth key.
# Used when intent is "register from scratch" — either prefs.LoggedOut
# was true, or BackendState reached NeedsLogin.
#
# Returns 1 on `tailscale up` failure so the caller can decide
# whether to skip the rest of its reconcile work.
#
# Args: <serverUrl> <hostname> <authKeyFile> <wantSsh> <wantAcceptRoutes>
# shellcheck disable=SC2329
ndh::headscaleClient:reregister() {
	local serverUrl="$1"
	local hostname="$2"
	local authKeyFile="$3"
	local wantSsh="$4"
	local wantAcceptRoutes="$5"

	# Idempotent logout to clear any stale node key (e.g. after a
	# headscale DB wipe or key rotation) that would otherwise trip
	# tailscale's LastNoiseDialWasRecent heuristic and force every
	# retry onto HTTPS:443 (which our plain-HTTP daemon doesn't serve).
	tailscale logout 2>/dev/null || true

	echo "[headscale] registering with ${serverUrl} as ${hostname} (authkey via ${authKeyFile})"

	# `--timeout=45s` caps tailscaled's wait for Running; without it
	# a missing/unhealthy headscale daemon makes `tailscale up`
	# block indefinitely, hanging surrounding callers (most
	# importantly `darwin-rebuild switch`'s setupLaunchAgents step
	# when invoked from the post-activation hook).
	local -a upArgs=(
		--timeout=45s
		--reset
		--login-server="$serverUrl"
		--authkey="$(tr -d '[:space:]' <"$authKeyFile")"
		--hostname="$hostname"
	)
	[[ "$wantSsh" == "true" ]] && upArgs+=(--ssh)
	[[ "$wantAcceptRoutes" == "true" ]] && upArgs+=(--accept-routes)

	if ! tailscale up "${upArgs[@]}"; then
		echo "⚠️  [headscale] tailscale up failed or timed out; try running hs-connect manually." >&2
		return 1
	fi
	echo "[headscale] registered"
	return 0
}

# Composite reconcile: combine the prefs/state decision tree into a
# single entry point.  Used by the post-activation hook.  Returns 0
# whether or not registration was performed (intent is "skip and
# warn on unhealthy state, don't fail activation").
#
# Args: <serverUrl> <hostname> <authKeyFile> <wantSsh> <wantAcceptRoutes>
# shellcheck disable=SC2329
ndh::headscaleClient:reconcile() {
	local serverUrl="$1"
	local hostname="$2"
	local authKeyFile="$3"
	local wantSsh="$4"
	local wantAcceptRoutes="$5"

	local prefsLoggedOut backendState

	prefsLoggedOut="$(ndh::headscaleClient:prefsLoggedOut)"
	if [[ -z "$prefsLoggedOut" ]]; then
		# `debug prefs` failed, usually because tailscaled isn't
		# reachable via its LocalAPI socket yet.  Treat as transient
		# and let the status-state retry below either confirm the
		# daemon is dead or wait it out.
		prefsLoggedOut="false"
	fi

	if [[ "$prefsLoggedOut" == "true" ]]; then
		if [[ -z "$authKeyFile" || ! -r "$authKeyFile" ]]; then
			echo "⚠️  [headscale] no auth key at '${authKeyFile:-<unset>}'; skipping autoconnect. Run hs-connect interactively."
			return 0
		fi
		ndh::headscaleClient:reregister "$serverUrl" "$hostname" "$authKeyFile" "$wantSsh" "$wantAcceptRoutes" || true
		return 0
	fi

	backendState="$(ndh::headscaleClient:waitBackendState 5 2)"
	case "$backendState" in
		Running)
			echo "[headscale] client already connected (BackendState=Running)"
			;;
		NeedsLogin)
			echo "[headscale] BackendState=NeedsLogin; re-registering with auth key"
			if [[ -z "$authKeyFile" || ! -r "$authKeyFile" ]]; then
				echo "⚠️  [headscale] no auth key at '${authKeyFile:-<unset>}'; skipping autoconnect. Run hs-connect interactively."
				return 0
			fi
			ndh::headscaleClient:reregister "$serverUrl" "$hostname" "$authKeyFile" "$wantSsh" "$wantAcceptRoutes" || true
			;;
		Starting|NoState)
			echo "⚠️  [headscale] BackendState=${backendState} after retry window; daemon still settling. Skipping reconcile; will retry on next activation or run hs-connect manually."
			;;
		*)
			echo "⚠️  [headscale] unexpected BackendState='${backendState}'. Skipping auto-recovery to preserve state. Run hs-connect manually if registration is genuinely lost."
			;;
	esac
	return 0
}
