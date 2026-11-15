# modules/home-manager/git.d

## OVERVIEW
Git Home Manager module: git config, hooks, sops filters, tests (32 files).

## STRUCTURE
feature.nix + hooks/ (tests), sops.d/, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Git config | default.nix / feature.nix |
| Hooks | hooks/ (tests/) |
| Sops filters | sops.d/ |
| Tests | tests/ (filters.bats) |

## CONVENTIONS
- Home Manager module; profile-aware.
- Hooks tested via bats.
- Sops filters guard secret material.

## ANTI-PATTERNS
- Don't edit .patch files without regenerating.
- Don't bypass sops filters for commits.
- Don't enable HM in bringup mode.

## NOTES
- hooks/ contains git hooks with tests.
- sops.d/ holds filter scripts.
- Run filters.bats via nix flake check.
- Verified against scan reports and spot-checked code.
