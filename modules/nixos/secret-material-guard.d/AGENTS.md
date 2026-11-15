# modules/nixos/secret-material-guard.d

## OVERVIEW
Bringup image secret scanner: guard.sh, canary-proven.d/, allow-list/hash, tests.

## STRUCTURE
guard.sh, canary-proven.d/record.sh, tests/, package.nix.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Guard logic | guard.sh |
| Canary proven | canary-proven.d/record.sh |
| Allow-list | guard.sh / tests |
| Tests | tests/ |

## CONVENTIONS
- NixOS-only; runs at image build.
- Refuses secret-shaped content unless allow-listed.
- xtrace-guarded for private material.

## ANTI-PATTERNS
- Don't let secret material into bringup images.
- Don't bypass allow-list without review.
- Don't weaken secret-shape regex.

## NOTES
- Security gate for images.
- allow-list maintenance is manual.
- Tests run via nix flake check.
- Verified against scan reports and spot-checked code.
