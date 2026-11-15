# modules/.common.d/attic-tokens.d

## OVERVIEW
Attic token fetch/unseal tooling with targets and tests.

## STRUCTURE
fetch.sh, unseal.sh, package.nix, targets.nix, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Fetch | fetch.sh (ndh-attic-tokens-fetch) |
| Unseal | unseal.sh (ndh-attic-tokens-unseal) |
| Targets | targets.nix |
| Tests | tests/ |

## CONVENTIONS
- xtrace-guarded for tokens.
- No plaintext in logs/argv.

## ANTI-PATTERNS
- Don't leak tokens to traces.
- Don't bypass targets.nix.

## NOTES
- High-risk secret handling.
- Tests run via nix flake check.
- Verified against scan reports and spot-checked code.
- Run nix flake check after changes.
- Run nix flake check after changes.
