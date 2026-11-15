---
name: host-provision
description: "Bootstrap or reinstall an ndh host (bioskop, nikopol, nerd-nixos): clone, sops secrets, rebuild, join tailnet. Use when adding a new host, recovering a machine, or re-running first-boot provisioning."
---

# Host Provision (ndh)

Bootstrap a host into the seedmatic fleet.

## When to use

- New machine or VM needs to become bioskop/nikopol/nerd-nixos.
- Host lost its config and must be re-provisioned.
- Testing a bringup image on a fresh guest.

## Preconditions

- Repo cloned at the fleet path; `nix develop` available.
- SOPS age key present (or bootstrap key delivered out of band).
- Network reachability to the tailnet control plane.

## Procedure

1. Enter the dev shell: `nix develop` (or `flox activate`).
2. Verify the flake: `nix flake check`.
3. Ensure secrets decrypt: `sops -d .secrets >/dev/null` or the host-specific secret file.
4. For NixOS: `sudo nixos-install --flake .#<host>-nixos` (bringup image: `.#<host>-bringup`).
5. For Darwin: `darwin-rebuild switch --flake .#<host>`.
6. Join the tailnet: `sudo tailscale up --authkey=...` (or the headscale equivalent).
7. Re-run the rebuild to converge: `nixos-rebuild switch` / `darwin-rebuild switch`.
8. Verify: `tailscale status`, `systemctl status` (NixOS) or `launchctl` (Darwin).

## Hosts

- `bioskop`: macOS siege + NixOS hypervisor (Tart).
- `nikopol`: roaming laptop.
- `nerd-nixos`: bringup/runtime target.

## Pitfalls

- Do not commit plaintext secrets; only sops-encrypted files.
- Darwin `/etc/exports` and provenance xattrs can block activation; see `[[reference/bioskop-nfs.md]]`.
- Bringup mode disables Home Manager; expect a second rebuild after provisioning.
- SIP on macOS may need to be disabled for certain activation steps.

## Related

- `nix-rebuild`, `secret-rotation`, `tailnet-ops`, `fleet-status`.
