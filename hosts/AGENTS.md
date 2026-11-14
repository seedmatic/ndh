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

## CONVENTIONS
- Hosts import modules/ + profile.
- Host-specific secrets via sops.
- Host profile drives enableHomeManager etc.

## ANTI-PATTERNS
- Don't hardcode paths; use catalog/inventory.
- Don't duplicate host-common logic per host.
## NOTES
- bioskop = siege Mac + NixOS hypervisor.
- nikopol = roaming laptop.
- Use host-common.nix for shared logic.
- Secrets via sops-nix.
- Note 1: see repository tree for full inventory.
- Note 2: see repository tree for full inventory.
- Note 3: see repository tree for full inventory.
