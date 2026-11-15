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
| Networking | ddns.nix, static-routes.d/, network-bond.d/, internet-sharing.d/ |
| Secrets/trust | cache-trust.nix, corp-egress-guard.d/, incus-remote-trust.d/, tls-authority-keychain.d/ |
| Bringup | bringup-observe.d/ |
| Headscale | headscale-client.d/, headscale-tools/ |
| NFS | nfs-autofs.d/, nfsd-off.d/ |
| Tart VMs | tart-config.d/ |
| Activation order | activation-order.d/ |
| SSH/keychain | ssh-keychain.d/, openssh.d/, restart-on-secret-change.d/ |

## CONVENTIONS
- Darwin-only; no isNixosPlatform guards needed.
- Assets in .d subdirs.
- Tests via bats in .d/tests where present.
- Activation scripts use @nixBashTrampoline@ + main().

## ANTI-PATTERNS
- Don't add Linux-only modules here.
- Don't edit .patch files without regenerating.
- Don't collapse introspection failures into "no ZFS" (tart).

## NOTES
- 27 feature subdirs; many are small toggles.
- Tests are bats in .d/tests where present.
- See child AGENTS.md for tart-config.d and nfs-autofs.d where present.
