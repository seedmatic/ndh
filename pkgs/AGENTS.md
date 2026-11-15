# pkgs

## OVERVIEW
Nix package definitions and bats tests for helper scripts.

## STRUCTURE
*.nix wrappers + *.sh helpers + *.bats tests + feature.d/ subdirs.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Package def | *.nix |
| Shell helpers | *.sh |
| Tests | *.bats, */tests/*.bats |
| Feature subdirs | baremetal-link.d/, incus-cluster-join.d/, vz-recover.d/ |

## CONVENTIONS
- Tests use bats; run via `nix flake check`.
- POSIX shell for helpers.
- One .nix per package.

## ANTI-PATTERNS
- Don't skip temp-dir isolation in bats.
- Don't put platform-specific code without guards.

## NOTES
- Helpers are POSIX shell.
- bats tests run in CI via flake check.
- bats uses temp dirs.
- Feature subdirs carry scripts + tests.
