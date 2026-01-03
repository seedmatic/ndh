#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
  if ! tailscale status >/dev/null 2>&1; then
    echo "⚠️  Headscale client is configured but not connected. Run: hs-connect"
  else
    echo "[headscale] Client already connected"
  fi
}

activation_run darwin.activationScripts.postActivation.headscale-client main "$@"
