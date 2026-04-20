#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
  if ! tailscale status >/dev/null 2>&1; then
    echo "⚠️  Headscale client is configured but not connected. Run: hs-connect"
  else
    echo "[headscale] Client already connected"
  fi
}

ndh::logger:command:run darwin.activationScripts.postActivation.headscale-client main "$@"
