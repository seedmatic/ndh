#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
  if ! tailscale status >/dev/null 2>&1; then
    echo "⚠️  Headscale client is configured but not connected. Run: hs-connect"
    return 0
  fi

  echo "[headscale] Client already connected"

  # Enforce Tailscale SSH (belt #2 — OpenSSH is belt #1).
  #
  # @enableSSH@ is the module's enableSSH flag baked in at nix-build time.
  # `tailscale set` patches persisted prefs without re-auth, so it's safe to
  # run on every switch and idempotent. Covers the drift case where a
  # previous `tailscale up` was run without --ssh (e.g. manual reconnect)
  # or where tailscaled restart cleared the runtime flag.
  want_ssh="@enableSSH@"
  current_ssh="$(tailscale debug prefs 2>/dev/null \
    | sed -n 's/.*"RunSSH": *\(true\|false\).*/\1/p' \
    | head -n1)"
  if [[ "$want_ssh" == "true" && "$current_ssh" != "true" ]]; then
    echo "[headscale] enabling Tailscale SSH (tailscale set --ssh=true)"
    tailscale set --ssh=true
  elif [[ "$want_ssh" == "false" && "$current_ssh" == "true" ]]; then
    echo "[headscale] disabling Tailscale SSH (tailscale set --ssh=false)"
    tailscale set --ssh=false
  fi
}

ndh::logger:command:run darwin.activationScripts.postActivation.headscale-client main "$@"
