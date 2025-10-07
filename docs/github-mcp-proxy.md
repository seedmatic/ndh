# GitHub MCP Proxy Module

This repository includes a local stdio JSON-RPC proxy (`github-mcp-proxy`) that allows IDEs (JetBrains, etc.) to access the GitHub Copilot MCP endpoint **without** hard-coding a long‑lived GitHub token into a static config file.

> Status: The module is **enabled by default** for all Darwin hosts via `modules/darwin/default.nix` (using `programs.githubMcpProxy.enable = lib.mkDefault true;`). Hosts can opt out explicitly.

## Why
The official MCP client configuration pattern currently expects static headers (e.g. `Authorization: Bearer <token>`). Storing a personal access token or session token in plain text is undesirable. This proxy fetches the token dynamically via the GitHub CLI (`gh auth token`), which uses the macOS Keychain, and injects `Authorization` at runtime.

## Disabling (if a host should not run it)
In a host-specific Darwin config:
```
programs.githubMcpProxy.enable = false;
```
Then rebuild.

## Customizing
```
programs.githubMcpProxy = {
  # (enable is already true by default, include only if overriding)
  # enable = true;
  remoteUrl = "https://api.githubcopilot.com/mcp"; # change only if upstream changes
  tokenCommand = "gh auth token";                  # wrapper allowed for custom token sourcing
  tokenTtlSeconds = 120;                           # reduce if you rotate rapidly
  extraEnvironment = { SOME_FLAG = "1"; };
};
```

## Using in `mcp.json`
Change your MCP client config to reference the stdio command instead of an HTTP server with static headers, e.g.:

```jsonc
{
  "servers": {
    "github": {
      "type": "stdio",
      "command": "github-mcp-proxy",
      "args": []
    }
  }
}
```
Remove any previous `headers.Authorization` entry. The proxy injects it dynamically.

## Dry Run / Health Check
```
echo '{"jsonrpc":"2.0","id":1,"method":"ping"}' | github-mcp-proxy --dry-run --verbose
```
Expected output (structure):
```
{"jsonrpc":"2.0","id":1,"result":{"dryRun":true,"method":"ping"}}
```

Self test (internal token cache + parser checks):
```
github-mcp-proxy --self-test
```

## Environment Variables (implicit defaults)
You may override at runtime without changing Nix options:
```
export GITHUB_MCP_TOKEN_COMMAND='security find-generic-password -s CopilotMCPToken -w'
export GITHUB_MCP_TOKEN_TTL=60
```

## Security Notes
- Token never written to disk by this proxy.
- `gh auth token` output is short-lived (depending on your auth flow) and backed by Keychain.
- No token logged (even with `--verbose`).
- If `gh` is not logged in, a JSON-RPC error with code `-32001` is returned.

## JSON-RPC Error Codes Used
| Code    | Meaning                                   |
|---------|-------------------------------------------|
| -32600  | Parse/invalid request structure           |
| -32001  | Token acquisition failure                 |
| -32002  | Upstream HTTP/network error               |
| -32000  | Internal unexpected error                 |

## Migrating from Old `bin/github-mcp-proxy`
A deprecated wrapper remains in `bin/` to ease transition. Remove or ignore it once all configurations reference `github-mcp-proxy` from your Nix profile. To silence its notice:
```
export GITHUB_MCP_PROXY_WRAPPER_SILENT=1
```

## Advanced: Alternate Token Source
Replace `tokenCommand` with a script that prints an ephemeral token (OIDC exchange, Keychain item, SOPS-decrypted secret) if you later adopt a more advanced flow.

## Uninstalling (per host)
```
programs.githubMcpProxy.enable = false;
```
Rebuild, then remove any references in your `mcp.json` if no longer needed.

## Future Enhancements (Ideas)
- Worker pool for concurrent forwarding
- Local method short-circuit (e.g., `health.ping` without upstream call)
- Prometheus-style metrics endpoint (switch to TCP server variant)
- Optional structured logging output channel

Contributions/requests: open an issue with the desired enhancement.
