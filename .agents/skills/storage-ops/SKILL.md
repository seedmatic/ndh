---
name: storage-ops
description: "Operate ZFS storage in ndh: datasets, snapshots, replication, pool health. Use when managing storage, taking backups, or debugging ZFS issues."
---

# Storage Ops (ndh)

Manage ZFS datasets and pools.

## When to use

- Creating or destroying datasets.
- Taking or restoring snapshots.
- Checking pool health and replication.

## Commands

```sh
zpool status
zfs list
zfs snapshot tank/data@snap
zfs send tank/data@snap | zfs receive backup/data
zfs rollback tank/data@snap
```

## Integration

- ZFS overlays mount `/nix/store` over the tank.
- ESP sync keeps secondary ESPs aligned.
- Shutdown ramfs exports pools cleanly.

## Pitfalls

- Do not destroy datasets without confirming backups.
- Snapshot names should be timestamped and retained per policy.
- Pool import failures can block boot; check vdev devices first.
- Replication requires network reachability and enough space.

## Related

- `incus-ops`, `nix-rebuild`, `fleet-status`.
