# overlays

## OVERVIEW
nixpkgs overlays and patches (devcontainer, docker-compose, incus, lazygit, mdpatch, python313, qemu, tailscale, vm-tools-deterministic, ...).

## STRUCTURE
*.nix overlays, *.patch, qemu/, devcontainer.d/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Overlay logic | *.nix |
| Patches | *.patch |
| QEMU patches | qemu/ |
| Devcontainer | devcontainer.d/ |

## CONVENTIONS
- Keep patches minimal; prefer upstream.
- Document why each patch exists.
- Applied in flake.nix.

## ANTI-PATTERNS
- Don't override core packages.
- Don't edit patches without regenerating.

## NOTES
- Test overlay changes via flake check.
- Patches must be minimal and justified.
- qemu/ and devcontainer.d/ hold sub-patches.
- Check `nix flake check` after overlay edits.
