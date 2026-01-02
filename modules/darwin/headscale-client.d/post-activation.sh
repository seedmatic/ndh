#!/usr/bin/env -S bash -xeuo pipefail
LOG="/var/log/darwin-headscale-client.log"
{
  if ! tailscale status >/dev/null 2>&1; then
    echo "⚠️  Headscale client is configured but not connected. Run: hs-connect"
  else
    echo "[headscale] Client already connected"
  fi
} >>"$LOG" 2>&1
