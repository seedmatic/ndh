{ lib, ... }:

# mDNS on NixOS is provided by systemd-resolved, not avahi.
#
# We used to run avahi here for `.local` resolution but hit a split-
# brain: libc consumers (`getent`, `ping`, anything cgo-free Go)
# routed through nsncd → libnss_mdns4 → avahi and worked fine, while
# native-Go resolvers (notably tailscaled) bypass NSS entirely and
# talk to `/etc/resolv.conf` → systemd-resolved, which at that point
# had `MulticastDNS=no` to avoid fighting avahi for UDP 5353.  Net
# effect: `getent hosts headscale.mammoth-skate.local` worked, but
# `tailscaled` with the same URL failed with "no DNS fallback
# candidates remain" and never registered the node.
#
# Simpler to run a single mDNS stack owned by resolved.  Downsides:
# resolved's mDNS is less battle-tested for service discovery than
# avahi (no _*._tcp browsing, no Bonjour service publication), but
# every consumer in the fleet that cares about `.local` — libc, Go,
# systemd unit scripts — goes through resolved uniformly.
#
# The actual toggle lives in resolved-lan.nix (MulticastDNS=yes on
# the LAN link).  This file just documents the migration and
# explicitly disables avahi so there's no lingering configuration
# drift if someone adds it back by accident.
{
  services.avahi.enable = lib.mkForce false;
}
