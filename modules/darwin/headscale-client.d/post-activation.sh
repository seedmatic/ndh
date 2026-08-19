#!/usr/bin/env -S bash -euo pipefail
# @codebase
# Darwin post-activation hook for the headscale client.
#
# Symmetric with the NixOS autoconnect unit
# (io-seedmatic-ndh-tailscaled-autoconnect): when a sops-
# materialised preauth key is available on disk, register the host
# against the headscale server non-interactively.  Otherwise fall back
# to the historic "emit a warning, operator runs hs-connect by hand"
# behaviour so a fresh laptop without the secret still boots cleanly.
#
# Reconcile decision tree lives in lib.sh's
# `ndh::headscaleClient:reconcile`.  Briefly: prefs.LoggedOut +
# bounded BackendState retry decide whether to re-register, leaving
# state untouched on transient daemon hiccups (which previously
# triggered tagged-node-expiry corruption on the headscale side
# during binary swaps).
#
# Notes:
#   - `--advertise-tags` is intentionally omitted: headscale v2 carries
#     tags on the preauth key itself and rejects client-asserted tags
#     on preauth registrations (hscontrol/state/state.go:1660 in
#     juanfont/headscale).
#   - Tailscale SSH is asserted idempotently after registration via
#     `tailscale set --ssh=<bool>` so an operator who manually ran
#     `tailscale up` without --ssh has their prefs reconciled on next
#     activation.

# shellcheck disable=SC1091
source @nixBashTrampoline@

# Shared decision-tree helpers (ndh::headscaleClient:reconcile et al.).
# Inlined verbatim by pkgs.replaceVars at build time so the whole script is
# visible to writeShellApplication's shellcheck pass.
@HEADSCALE_CLIENT_LIB_INLINE@

main() {
	local authKeyFile="@authKeyFile@"
	local wantSsh="@enableSSH@"
	local wantAcceptRoutes="@acceptRoutes@"
	local serverUrl="@serverUrl@"
	local hostname="@hostname@"

	ndh::headscaleClient:reconcile \
		"$serverUrl" \
		"$hostname" \
		"$authKeyFile" \
		"$wantSsh" \
		"$wantAcceptRoutes"

	# Enforce Tailscale SSH (belt #2 — OpenSSH is belt #1).  `tailscale
	# set` patches persisted prefs without re-auth, so it's safe to run
	# on every switch and is idempotent.  Covers the drift case where a
	# previous `tailscale up` ran without --ssh or a tailscaled restart
	# cleared the runtime flag.
	local currentSsh
	currentSsh="$(tailscale debug prefs 2>/dev/null \
		| sed -n 's/.*"RunSSH": *\(true\|false\).*/\1/p' \
		| head -n1)"
	if [[ "$wantSsh" != "$currentSsh" ]]; then
		tailscale set --ssh="$wantSsh" \
			|| echo "⚠️  [headscale] failed to set Tailscale SSH. Run: tailscale set --ssh=$wantSsh"
	fi

	# Reconcile-check: compare `.secrets` against the live headscale
	# server and warn on drift (missing user, preauth keys in .secrets
	# that don't exist server-side, tags disagreeing with catalog).
	# Read-only — never mutates.  Timeout-capped and failure-tolerant
	# so an unreachable daemon doesn't hang or fail activation.  The
	# mutating counterpart is `hs mint`, invoked by the operator only.
	if command -v hs >/dev/null 2>&1; then
		timeout 10 hs check 2>&1 \
			|| echo "⚠️  [headscale] hs check warn (non-blocking; inspect output above)"
	fi
}

ndh::logger:command:run darwin.activationScripts.postActivation.headscale-client main "$@"
