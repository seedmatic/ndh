---
name: fleet-status
description: Report ndh fleet inventory and health: hosts, services, storage, tailnet. Use when checking overall fleet state or preparing a change.
---

# Fleet Status (ndh)

Summarize fleet state and health.

## When to use

- Before and after a fleet-wide change.
- Investigating an outage or degraded host.
- Preparing a maintenance window.

## Commands

```sh
nix flake show
tailscale status
zpool status
systemctl --failed
launchctl list | grep ndh
```

## Inventory

- Hosts: bioskop (Darwin + NixOS hypervisor), nikopol (laptop), nerd-nixos (runtime).
- Roles: bringup, system, user.
- Profiles drive host composition via `ndh.context`.

## Health checks

- Tailnet connectivity between all nodes.
- Storage pool health and free space.
- Failed systemd/launchd units.
- Secret material presence (without printing values).

## Pitfalls

- Bringup hosts have Home Manager disabled; expect fewer services.
- A green `nix flake check` does not prove runtime health.
- Do not expose secret values in status output.

## Related

- `host-provision`, `nix-rebuild`, `storage-ops`.
