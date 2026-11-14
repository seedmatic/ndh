# modules/darwin

## OVERVIEW
macOS (nix-darwin) specific modules: 130 files, 27 feature subdirs.

## STRUCTURE
feature.nix + feature.d/ (assets, tests). Key: core.nix, default.nix, host-builder.nix, display-manager.nix, homebrew.nix.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Core darwin | core.nix, default.nix |
| Host builder | host-builder.nix + host-builder.d/ |
| Networking | ddns.nix, static-routes.d/ |
| Secrets/trust | cache-trust.nix, corp-egress-guard.* |
| Bringup | bringup-observe.* |
| Headscale | headscale-client.d/, headscale-tools/ |
| NFS | nfs-autofs.d/, nfsd-off.d/ |

## CONVENTIONS
- Darwin-only; no isNixosPlatform guards needed.
- Assets in .d subdirs.
- Tests via bats in .d/tests where present.

## ANTI-PATTERNS
- Don't add Linux-only modules here.
- Don't edit .patch files without regenerating.
## NOTES
- 27 feature subdirs; many are small toggles.
- Tests are bats in .d/tests where present.
