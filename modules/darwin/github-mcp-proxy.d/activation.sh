#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
  if command -v github-mcp-proxy >/dev/null 2>&1; then
    echo "[github-mcp-proxy] installed: $(command -v github-mcp-proxy)"
  else
    echo "[github-mcp-proxy][WARN] binary not on PATH"
  fi
}

ndh::logger:command:run darwin.activationScripts.postActivation.github-mcp-proxy main "$@"
