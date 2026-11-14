# modules/nixos

## OVERVIEW
NixOS-specific modules: 143 files, 12 feature subdirs (incus, zfs, attic, systemd, ...).

## STRUCTURE
feature.nix + feature.d/. Key: default.nix, boot-loader.nix, disko.nix, incus.nix, zfs.d/, systemd/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Boot/disk | boot-loader.nix, disko.nix |
| Containers | incus.nix, incus.d/, incus-nixos-container.nix |
| Storage | zfs.d/, erofs-store-*.nix |
| Systemd units | systemd/ |
| Bringup images | bringup-*.nix |
| Attic cache | attic-cache.d/, attic-client.nix |

## CONVENTIONS
- NixOS-only.
- Image builds use erofs.
- Bringup images disable Home Manager.

## ANTI-PATTERNS
- Don't put darwin config here.
## NOTES
- 12 feature subdirs; systemd/ has nested units.
- Bringup images use erofs for reproducibility.
- Prefer nixos-rebuild for apply.
- Modules imported by hosts.
