# modules/darwin/nfs-autofs.d

## OVERVIEW
NFS/autofs machinery: synthetic.conf dedup, auto_master, 8 scripts.

## STRUCTURE
8 scripts + tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Autofs config | scripts/ (auto_master) |
| NFS server off | ../nfsd-off.d/ |
| Tests | tests/ |

## CONVENTIONS
- Darwin-only activation scripts.
- Use @nixBashTrampoline@ substitution.

## ANTI-PATTERNS
- Don't duplicate auto_master entries.
- Don't enable legacy nfsd.

## NOTES
- Scripts mutate system autofs state.
- Tests via nix flake check.
- Verified against scan reports and spot-checked code.
- Run nix flake check after changes.
- Run nix flake check after changes.
- Run nix flake check after changes.
