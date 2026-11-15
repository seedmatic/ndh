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
