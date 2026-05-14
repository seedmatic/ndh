#!/usr/bin/env -S bash -euo pipefail
# @codebase
# Darwin post-activation hook for the headscale client.
#
# Symmetric with the NixOS autoconnect unit
# (io-nxmatic-nix-darwin-home-tailscaled-autoconnect): when a sops-
# materialised preauth key is available on disk, register the host
# against the headscale server non-interactively.  Otherwise fall back
# to the historic "emit a warning, operator runs hs-connect by hand"
# behaviour so a fresh laptop without the secret still boots cleanly.
#
# Notes:
#   - `tailscale up --reset` clears any stale prefs that would
#     otherwise make `tailscale up` refuse to re-register with a
#     different flag set (seen when we flipped off `--advertise-tags`
#     after headscale v2 started rejecting it on preauth-key flows).
#   - `--advertise-tags` is intentionally omitted: headscale v2 carries
#     tags on the preauth key itself and rejects client-asserted tags
#     on preauth registrations (hscontrol/state/state.go:1660 in
#     juanfont/headscale).
#   - Tailscale SSH is asserted idempotently after registration via
#     `tailscale set --ssh=<bool>` so an operator who manually ran
#     `tailscale up` without --ssh has their prefs reconciled on next
#     activation.
source @nixBashTrampoline@

main() {
  local authKeyFile="@authKeyFile@"
  local wantSsh="@enableSSH@"
  local wantAcceptRoutes="@acceptRoutes@"
  local serverUrl="@serverUrl@"
  local hostname="@hostname@"

  # Fast path: already connected.  `tailscale status` returns non-zero
  # only when logged out, so this catches both the "same generation"
  # and "re-applied switch without state change" cases cheaply.
  if tailscale status >/dev/null 2>&1; then
    echo "[headscale] client already connected"
  else
    if [[ -z "$authKeyFile" || ! -r "$authKeyFile" ]]; then
      echo "⚠️  [headscale] no auth key at '${authKeyFile:-<unset>}'; skipping autoconnect. Run hs-connect interactively."
      return 0
    fi

    # Always start from a known-logged-out state before re-registering
    # with a preauth key.  A stale node-key (e.g. after a headscale DB
    # wipe or key rotation) would otherwise make `tailscale up` try to
    # re-auth with a key the server no longer knows, fail, flip the
    # "LastNoiseDialWasRecent" heuristic on, and then force every
    # retry onto HTTPS:443 (which our plain-HTTP daemon doesn't serve).
    # `tailscale logout` is idempotent.
    tailscale logout 2>/dev/null || true

    echo "[headscale] registering with ${serverUrl} as ${hostname} (authkey via ${authKeyFile})"
    # `--timeout=45s` is tailscale's own bound on the tailscaled-
    # Running wait; without it, a missing/unhealthy headscale daemon
    # makes `tailscale up` block indefinitely, hanging the surrounding
    # `darwin-rebuild switch`'s setupLaunchAgents / zdotdir steps.  The
    # hook is best-effort: on timeout we warn and return cleanly so
    # the rest of activation proceeds; the operator reruns hs-connect
    # (or the next activation retries) once the daemon is up.
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
      return 0
    fi
    echo "[headscale] registered"
  fi

  # Enforce Tailscale SSH (belt #2 — OpenSSH is belt #1).  `tailscale
  # set` patches persisted prefs without re-auth, so it's safe to run
  # on every switch and is idempotent.  Covers the drift case where a
  # previous `tailscale up` ran without --ssh or tailscaled restart
  # cleared the runtime flag.
  local currentSsh
  currentSsh="$(tailscale debug prefs 2>/dev/null \
    | sed -n 's/.*"RunSSH": *\(true\|false\).*/\1/p' \
    | head -n1)"
  if [[ "$wantSsh" != "$currentSsh" ]]; then
    tailscale set --ssh=$wantSsh ||
      echo "⚠️  [headscale] failed to set Tailscale SSH. Run: tailscale set --ssh=$wantSsh"
  fi

  # Reconcile-check: compare `.secrets` against the live headscale
  # server and warn on drift (missing user, preauth keys in .secrets
  # that don't exist server-side, tags disagreeing with catalog).
  # Read-only — never mutates.  Timeout-capped and failure-tolerant
  # so an unreachable daemon doesn't hang or fail activation.  The
  # mutating counterpart is `hs mint`, invoked by the operator only.
  if command -v hs >/dev/null 2>&1; then
    timeout 10 hs check 2>&1 || \
      echo "⚠️  [headscale] hs check warn (non-blocking; inspect output above)"
  fi
}

ndh::logger:command:run darwin.activationScripts.postActivation.headscale-client main "$@"
