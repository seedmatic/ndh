# modules/nixos/systemd

## OVERVIEW
NixOS systemd unit wiring: openssh, ssh-keys enrichment, buildkitd, containerd, tart agents/shares, rescue, initrd, manual switch, profile symlinks, bringup target.

## STRUCTURE
*.nix unit modules + scripts/ + openssh.d/ (activation, autostart check, tests).

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Unit naming | naming.nix (ndhSystemd) |
| OpenSSH policy | openssh.nix, openssh.d/ |
| SSH key enrichment | ssh-keys-enrichment.nix |
| Build/containerd | buildkitd.nix, containerd.nix |
| Tart guests/shares | tart-guest-agent.nix, tart-host-shares.nix |
| Rescue/manual switch | rescue.nix, manual-switch.nix, *.sh |
| Bringup target | bringup-target-activate.nix |
| HM state dirs | hm-state-dirs.nix |

## CONVENTIONS
- NixOS-only; units use ndhSystemd naming helpers.
- Externalized scripts use ndh.store.* (not writeShellScript).
- mkDefault/mkForce priority discipline.

## ANTI-PATTERNS
- Don't bypass ndhSystemd naming for new units.
- Don't use bare pkgs.writeShellScript for externalized scripts.
- Don't overuse mkForce.

## NOTES
- openssh.d/ has activation + autostart check + bats.
- manual-switch scripts handle nixos-rebuild-guest.
- Tests run via nix flake check.