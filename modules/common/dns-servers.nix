{ lib, ... }:
{
  # Common DNS server configuration for both IPv4 and IPv6
  # Used across NixOS and Darwin configurations
  # Note: Tailscale DNS (100.100.100.100) is managed by the Tailscale module

  options.common.dnsServers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      # Cloudflare DNS (IPv6)
      "2606:4700:4700::1111"
      "2606:4700:4700::1001"

      # Google DNS (IPv6)
      "2001:4860:4860::8888"
      "2001:4860:4860::8844"

      # Cloudflare DNS (IPv4)
      "1.1.1.1"
      "1.0.0.1"

      # Google DNS (IPv4)
      "8.8.8.8"
      "8.8.4.4"
    ];
    description = "Default public DNS servers with IPv6 and IPv4 support (Cloudflare and Google)";
  };
}
