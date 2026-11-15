# modules/home-manager/ssh.d

## OVERVIEW
SSH Home Manager module: config generation, zones, scripts, tests (24 files).

## STRUCTURE
feature.nix + config.d/ (zones.d/), scripts/, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| SSH config | feature.nix / config.d/ |
| Zones | config.d/zones.d/ |
| Scripts | scripts/ |
| Tests | tests/ |

## CONVENTIONS
- Home Manager module; profile-aware.
- Config generated from catalog/inventory.
- Tests via bats.

## ANTI-PATTERNS
- Don't hardcode host entries; derive from catalog.
- Don't enable HM in bringup mode.
- Don't duplicate shared SSH logic from .common.d.

## NOTES
- config.d/zones.d/ holds per-zone fragments.
- scripts/ holds helper scripts.
- Run tests via nix flake check.
- Verified against scan reports and spot-checked code.
