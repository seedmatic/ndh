# modules/darwin/tart-config.d

## OVERVIEW
Tart VM config and activation: disk materialization, recreate guard, factory reset, VM launcher.

## STRUCTURE
activation.sh (~1400 lines), run.sh, tests/recreate-guard.bats, tests/package.nix.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Activation | activation.sh |
| VM launch | run.sh |
| Recreate guard | activation.sh (tart:vm:recreate:guard) |
| Tests | tests/recreate-guard.bats |

## CONVENTIONS
- Disks resolved from bringup manifest (no guessed layout).
- ZFS pools detected via partition hints.
- Guard refuses recreate when data disk holds ZFS or unreadable.

## ANTI-PATTERNS
- Don't collapse "cannot introspect" into "no ZFS".
- Don't replace store-layer content while preserving ESP/root.
- Don't materialize a guessed disk set.

## NOTES
- Activation runs in Darwin post-activation.
- Tests run via bats.
- Verified against scan reports and spot-checked code.
