# modules/nixos

## OVERVIEW
NixOS-specific modules: 143 files, 12 feature subdirs (incus, zfs, attic, systemd, ...).

## STRUCTURE
feature.nix + feature.d/. Key: default.nix, boot-loader.nix, disko.nix, incus.nix, zfs.d/, systemd/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Boot/disk | boot-loader.nix, disko.nix |
| Containers | incus.nix, incus.d/, incus-nixos-container.nix, incus-nixos-container.d/ |
| Storage | zfs.d/, erofs-store-*.nix, store-freeze.d/ |
| Systemd units | systemd/ |
| Bringup images | bringup-*.nix, bringup-zfs-disk-image.d/, erofs-store-image.d/ |
| Attic cache | attic-cache.d/, attic-client.nix |
| Secret guard | secret-material-guard.d/ |
| SSHFS mounts | sshfs-mounts.nix, sshfs-mounts.d/ |
| Baremetal | baremetal-segment.d/ |

## CONVENTIONS
- NixOS-only.
- Image builds use erofs.
- Bringup images disable Home Manager.
- Tests via bats in *.d/tests.

## ANTI-PATTERNS
- Don't put darwin config here.
- Don't write Incus config key-by-key; use whole-config edit.

## NOTES
- 12 feature subdirs; systemd/ has nested units.
- Bringup images use erofs for reproducibility.
- Prefer nixos-rebuild for apply.
- Modules imported by hosts.
- See child AGENTS.md for systemd, store-freeze.d, secret-material-guard.d, attic-cache.d,
  incus-nixos-container.d where present.
