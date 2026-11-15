---
name: tailnet-ops
description: "Operate the tailnet (Tailscale/Headscale) for ndh: node status, joining, ACLs, split DNS. Use when adding nodes, debugging connectivity, or changing tailnet policy."
---

# Tailnet Ops (ndh)

Manage tailnet nodes and policy.

## When to use

- Adding bioskop/nikopol/nerd-nixos to the tailnet.
- Debugging DNS resolution or reachability.
- Updating ACLs or split-DNS settings.

## Commands

```sh
tailscale status
tailscale up
tailscale ping <host>
tailscale set --accept-dns=true
headscale nodes list
headscale routes list
```

## Split DNS

- Fleet domains resolve via the tailnet control plane.
- Corp networks may require `--accept-dns=false` on roaming machines.
- Verify with `resolvectl query` or `dig`.

## Pitfalls

- nikopol is often off-tailnet on corp networks; use LAN IP or bridge subnet.
- bioskop exports must allow the guest subnet (172.16.8.0/30).
- ACL changes can silently drop connectivity; test from a second node.

## Related

- `network-debug`, `host-provision`, `fleet-status`.
