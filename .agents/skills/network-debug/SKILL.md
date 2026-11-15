---
name: network-debug
description: Debug ndh networking: Tailscale, DNS, NFS, Kerberos. Use when resolving connectivity, name resolution, or mount failures.
---

# Network Debug (ndh)

Diagnose network issues across the fleet.

## When to use

- A host cannot reach another host or service.
- DNS resolution fails for tailnet or corp names.
- NFS mounts fail or exports are missing.
- Kerberos authentication fails.

## Commands

```sh
tailscale status
tailscale ping <host>
resolvectl query <name>
dig <name>
showmount -e <server>
nfsstat -m
klist
journalctl -u nfs-server
```

## Common cases

- NFS: check exports include the client subnet; verify `/etc/exports` on Darwin.
- DNS: check split DNS and corp resolver precedence.
- Tailnet: verify node is connected and ACLs allow the path.
- Kerberos: check ticket expiry and keytab.

## Pitfalls

- `showmount` can succeed even when mounts are denied.
- mDNS may resolve to a bridge IP not in exports.
- Corp DNS can override tailnet DNS on roaming machines.

## Related

- `tailnet-ops`, `incus-ops`, `fleet-status`.
