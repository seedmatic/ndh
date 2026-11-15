# modules/.common.d/shell.d

## OVERVIEW
Shared Bash runtime: logger, trampoline, post-activation, store-asset-lookup, activation-logger shim.

## STRUCTURE
logger.sh, nix-bash-trampoline.sh, post-activation.sh, store-asset-lookup.sh, activation-logger.sh, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Logging/run markers | logger.sh |
| Trampoline | nix-bash-trampoline.sh |
| HM activation | post-activation.sh |
| Store asset lookup | store-asset-lookup.sh |
| Tests | tests/ |

## CONVENTIONS
- POSIX-ish Bash with set -euo pipefail.
- @nixBashTrampoline@ substitution.
- ndh::logger:command:run entrypoint.

## ANTI-PATTERNS
- Don't bypass trampoline (no caller PATH).
- Don't skip secret begin/end windows.
- Don't edit trampoline without tests.

## NOTES
- Large shared runtime; many callers.
- logger.sh has run markers, hints, stream redirection.
- Verified against scan reports and spot-checked code.
