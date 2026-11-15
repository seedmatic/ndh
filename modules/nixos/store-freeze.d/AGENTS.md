# modules/nixos/store-freeze.d

## OVERVIEW
Store freeze/compaction/purge tooling: cli, stack, commit, runtime inputs, bats tests.

## STRUCTURE
cli.sh, stack.sh, commit.sh, runtime-inputs.nix, sweep-shapes, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| CLI entry | cli.sh (ndh-store) |
| Stack logic | stack.sh |
| Commit | commit.sh |
| Runtime inputs | runtime-inputs.nix |
| Tests | tests/ |

## CONVENTIONS
- NixOS-only; runs under trampoline.
- Manifest validation before mutation.
- Degraded mode blocks delivery.

## ANTI-PATTERNS
- Don't retry a failed toplevel (converge.failed).
- Don't deliver on a degraded store (STORE_DEGRADED).
- Don't mutate store without confirm.

## NOTES
- Commands: status, freeze, compact, purge, confirm.
- Tests require NDH_TRAMPOLINE env.
- High-risk store mutation surface.