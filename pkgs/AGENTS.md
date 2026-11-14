# pkgs

## OVERVIEW
Nix package definitions and bats tests for helper scripts.

## STRUCTURE
*.nix wrappers + *.sh helpers + *.bats tests.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Package def | *.nix |
| Shell helpers | *.sh |
| Tests | *.bats |

## CONVENTIONS
- Tests use bats; run via `nix flake check`.
- POSIX shell for helpers.
## NOTES
- Helpers are POSIX shell.
- bats tests run in CI via flake check.
- One .nix per package.
- bats uses temp dirs.
- Note 1: see repository tree for full inventory.
- Note 2: see repository tree for full inventory.
- Note 3: see repository tree for full inventory.
- Note 4: see repository tree for full inventory.
- Note 5: see repository tree for full inventory.
- Note 6: see repository tree for full inventory.
- Note 7: see repository tree for full inventory.
