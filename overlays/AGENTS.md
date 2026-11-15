# overlays

## OVERVIEW
nixpkgs overlays and patches.

## STRUCTURE
*.nix overlays, *.patch.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Overlay logic | *.nix |
| Patches | *.patch |

## CONVENTIONS
- Keep patches minimal; prefer upstream.
- Document why each patch exists.
## NOTES
- Overlays applied in flake.nix.
- Test overlay changes via flake check.
- Avoid overriding core packages.
