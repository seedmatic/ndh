---
name: incus-ops
description: Manage Incus instances and per-metalspace segments in ndh. Use when creating instances, fixing socket permissions, or operating Incus remotes.
---

# Incus Ops (ndh)

Operate Incus containers and segments.

## When to use

- Creating or deleting Incus instances for a metalspace.
- Fixing socket permissions or remote trust.
- Inspecting instance networks and profiles.

## Commands

```sh
incus list
incus info <name>
incus exec <name> -- <cmd>
incus profile list
incus network list
incus remote list
```

## Segments

- Per-metalspace Incus segments are advertised into the tailnet.
- Split DNS resolves `vzhost.<domain>` and instance names.
- Keep segment CIDRs aligned with `catalog/`.

## Pitfalls

- Socket permissions may need `incus-user-config` activation.
- Remote trust requires certificate exchange; do not skip verification.
- ZFS storage pools must be imported before instance start.

## Related

- `storage-ops`, `network-debug`, `fleet-status`.
