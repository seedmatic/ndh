# packages

## OVERVIEW
Go helper programs built via Nix.

## STRUCTURE
go.mod, *.go, default.nix.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Go source | *.go |
| Module deps | go.mod, go.sum |
| Nix build | default.nix |

## CONVENTIONS
- Go modules; build with nix.
- Keep helpers small and focused.
## NOTES
- Built and tested via nix flake check.
- Nix wraps the Go build.
- Keep Go deps vendored.
