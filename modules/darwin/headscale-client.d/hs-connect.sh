# shellcheck shell=bash
# hs-connect: operator-facing wrapper around the same reconcile helper
# the post-activation hook uses.  Lets a human force a best-effort
# reconnect/re-register from any shell, with the same safe-by-default
# semantics (preserve state on transient hiccups, only logout+reset
# when intent or BackendState clearly says so).
#
# Build-time substitutions (pkgs.replaceVars in modules/darwin/headscale.nix):
# nixBashTrampoline, HEADSCALE_CLIENT_LIB_INLINE, serverUrl, hostname,
# authKeyFile, enableSSH, acceptRoutes.

# shellcheck disable=SC1091
source @nixBashTrampoline@

# Shared decision-tree helpers — see modules/darwin/headscale-client.d/lib.sh.
@HEADSCALE_CLIENT_LIB_INLINE@

main() {
	local serverUrl="@serverUrl@"
	local hostname="@hostname@"
	local authKeyFile="@authKeyFile@"
	local wantSsh="@enableSSH@"
	local wantAcceptRoutes="@acceptRoutes@"

	ndh::headscaleClient:reconcile \
		"$serverUrl" \
		"$hostname" \
		"$authKeyFile" \
		"$wantSsh" \
		"$wantAcceptRoutes"
}

main "$@"
