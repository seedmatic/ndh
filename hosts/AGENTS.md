# hosts

## OVERVIEW
Per-host definitions: bioskop (macOS siege + hypervisor), nikopol (roaming laptop), nerd-nixos, host-common.nix.

## STRUCTURE
hosts/<name>/ contains host config importing modules. host-common.nix shared.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Host entry | hosts/<name>/default.nix (or *.nix) |
| Shared host logic | host-common.nix |
| Host modules | hosts/<name>/modules/ |
| Host assets | hosts/<name>/assets.d/ |
| Inventory | inventory/default.nix |

## CONVENTIONS
- Hosts import modules/ + profile.
- Host-specific secrets via sops.
- Host profile drives enableHomeManager etc.
- Shared logic in host-common.nix; don't duplicate.

## ANTI-PATTERNS
- Don't hardcode paths; use catalog/inventory.
- Don't duplicate host-common logic per host.
- Don't put platform config directly in host dirs; use modules/.

## NOTES
- bioskop = siege Mac + NixOS hypervisor.
- nikopol = roaming laptop.
- nerd-nixos = minimal NixOS host.
- Secrets via sops-nix.
- Host profiles: bringup / system / user.
