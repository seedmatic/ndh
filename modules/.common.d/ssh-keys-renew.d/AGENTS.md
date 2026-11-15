# modules/.common.d/ssh-keys-renew.d

## OVERVIEW
Key renewal CLI: plan/build, renew/apply, record public-only, revoke cert, record nix-signing.

## STRUCTURE
package.nix, ssh-keys-renew.sh (1194 lines), tests/package.nix, tests/renew.bats.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| CLI | ssh-keys-renew.sh |
| Package | package.nix |
| Tests | tests/renew.bats |

## CONVENTIONS
- Safe by default: dry run unless --apply.
- stdout (not stderr) carries plan/refusals.
- PATH pinned to package store paths; LC_ALL=C.
- Tools from bringup runtime profile contract.

## ANTI-PATTERNS
- Don't mix --create with --key/--authority/--older-than/--replace.
- --create names must match ^[a-z][a-z0-9-]*$.
- --public takes only - (stdin), never a path.
- Recorded public must be ed25519 and unique.

## NOTES
- Complex yq/sops handling.
- Tests run against real sops/age.
- Verified against scan reports and spot-checked code.
