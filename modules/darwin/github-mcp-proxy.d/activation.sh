#!/usr/bin/env -S bash -xeuo pipefail
LOG="/var/log/darwin-github-mcp-proxy.log"
{
  if command -v github-mcp-proxy >/dev/null 2>&1; then
    echo "[github-mcp-proxy] installed: $(command -v github-mcp-proxy)"
  else
    echo "[github-mcp-proxy][WARN] binary not on PATH"
  fi
} >>"$LOG" 2>&1
