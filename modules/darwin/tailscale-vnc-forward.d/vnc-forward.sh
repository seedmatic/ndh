#!/usr/bin/env -S bash -euo pipefail
# @nixBashTrampoline@

# Check if we're connected to tailscale
if ! @tailscale@ status --json | @jq@ -e '.Self.Online' >/dev/null 2>&1; then
  logger -t "@loggerTag@" "Tailscale not connected, skipping VNC forward"
  exit 0
fi

# Check if bioskop is reachable on tailnet
if ! @tailscale@ status --json | @jq@ -e ".Peer[] | select(.HostName == \"bioskop\")" >/dev/null 2>&1; then
  logger -t "@loggerTag@" "bioskop not reachable on tailnet, skipping VNC forward"
  exit 0
fi

logger -t "@loggerTag@" "Setting up VNC port forward: nikopol:5901 -> @bioskopHost@:5900"

# Set up SSH tunnel in background with auto-reconnect
# -f: background, -N: no command, -T: no PTY
# ExitOnForwardFailure: exit if port forward fails
# ServerAliveInterval: keep connection alive
# NOTE: Bind to 0.0.0.0:5901 so vz-host (bare metal) can connect to bioskop's VNC via nikopol
# nikopol's Screen Sharing uses 5900 for direct vz-host access
exec @ssh@ \
  -f -N -T \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=accept-new \
  -L 0.0.0.0:5901:@bioskopHost@:5900 \
  nxmatic@@@bioskopHost@
