{ lib, ... }:
{
  # Common DNS server configuration for both IPv4 and IPv6
  # Used across NixOS and Darwin configurations
  # Note: Tailscale DNS (100.100.100.100) is managed by the Tailscale module

  # Trimmed to the resolver standard: at most 3 nameservers in
  # /etc/resolv.conf are honored by glibc and explicitly enforced by
  # kubelet (anything beyond is silently dropped, surfaced as
  # `DNSConfigForming` events on every pod). The earlier 8-entry list
  # (IPv4 + IPv6, Cloudflare + Google primary + secondary) was
  # over-engineered: the secondaries gave no real resilience because
  # any failover had to happen within a single sub-3 window anyway.
  #
  # The shape below picks three providers spanning IPv6 + IPv4 + a
  # second IPv4 vendor — that's the resilience knob that actually
  # matters: independent providers, independent transports.
  options.common.dnsServers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "2606:4700:4700::1111" # Cloudflare DNS (IPv6)
      "1.1.1.1" # Cloudflare DNS (IPv4)
      "8.8.8.8" # Google DNS (IPv4) — second-vendor fallback
    ];
    description = ''
      Default public DNS servers used by hosts whose `networking.nameservers`
      are derived from this option (e.g., the `mammoth-skate` NixOS guest).
      Limited to 3 entries to stay under the resolver standard / kubelet
      preflight cap; the trio mixes one IPv6 entry, two IPv4 entries, and
      two independent vendors (Cloudflare + Google) so a single-vendor
      outage still resolves.
    '';
  };
}
