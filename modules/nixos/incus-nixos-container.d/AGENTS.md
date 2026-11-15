# modules/nixos/incus-nixos-container.d

## OVERVIEW
Incus NixOS container lifecycle: cli.sh, store.sh, tests (converge/deliver/rollback).

## STRUCTURE
cli.sh (~1800 lines), store.sh, tests/cli.bats, tests/package.nix.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| CLI verbs | cli.sh (list/create/deliver/converge/rollback) |
| Store mount | store.sh |
| Tests | tests/cli.bats |

## CONVENTIONS
- ZFS datasets per container; overlay store (snapshot + EROFS).
- Unprivileged containers cannot write store.
- Converge is idempotent; failed toplevel blocks retry.

## ANTI-PATTERNS
- Don't write Incus config key-by-key (use config edit).
- Don't deliver on degraded store (STORE_DEGRADED).
- Don't mkdir -p through container-writable paths.
- Don't rename dataset while mounted/busy.

## NOTES
- Heaviest logic in cli.sh.
- Tests need NDH_TRAMPOLINE + bootstrap profile.
- Run via nix flake check.
- Verified against scan reports and spot-checked code.
