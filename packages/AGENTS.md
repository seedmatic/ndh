# packages

## OVERVIEW
Go helper programs built via Nix: ndh-mdns-publish, ndh-nix-signing-derive.

## STRUCTURE
Per-helper dir with *.go, go.mod, default.nix; tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Go source | <helper>/*.go |
| Module deps | <helper>/go.mod, go.sum |
| Nix build | <helper>/default.nix |
| Tests | <helper>/*_test.go |

## CONVENTIONS
- Go modules; build with nix.
- Keep helpers small and focused.
- Nix wraps the Go build.

## ANTI-PATTERNS
- Don't commit unvetted deps; keep deps vendored.
- Don't add platform-specific code without guards.

## NOTES
- Built and tested via nix flake check.
- ndh-nix-signing-derive locks a known vector.
- ndh-mdns-publish publishes mDNS A records.
- Keep Go deps vendored and tested.
