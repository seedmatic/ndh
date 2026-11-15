# modules/nixos/attic-cache.d

## OVERVIEW
Private Attic cache lifecycle: ensure, publish, server secret, token mint, paths.

## STRUCTURE
cache-ensure.sh, publish.sh, server-secret.sh, token-mint.sh, paths.nix, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Cache ensure | cache-ensure.sh |
| Publish | publish.sh |
| Server secret | server-secret.sh |
| Token mint | token-mint.sh |
| Paths | paths.nix |
| Tests | tests/ |

## CONVENTIONS
- NixOS-only; xtrace-guarded for tokens.
- Private cache; no plaintext in logs.

## ANTI-PATTERNS
- Don't leak server secrets to traces/argv.
- Don't publish without trust statements.
- Don't bypass token minting.

## NOTES
- Used by attic-client and hosts.
- Tests run via nix flake check.
- Verified against scan reports and spot-checked code.
