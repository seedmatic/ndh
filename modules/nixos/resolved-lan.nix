{ lib, ... }:
{
  # Prefer the home router DNS on the primary LAN link (enp0s1) instead of public resolvers.
  # Uses mkDefault so host-specific configs can override if needed. (@codebase)
  services.resolved = {
    enable = lib.mkDefault true;
    # extraConfig was removed in 26.05 — resolved.conf is now built from
    # settings.Resolve (the old fallbackDns/domains/llmnr options are aliases into it).
    settings.Resolve = {
      DNS = lib.mkDefault "192.168.1.254";
      FallbackDNS = lib.mkDefault "";
      Domains = lib.mkDefault "lan";
      MulticastDNS = lib.mkDefault "yes";
      LLMNR = lib.mkDefault "no";
    };
  };

  # Keep networking.nameservers aligned with resolved.
  networking.nameservers = lib.mkDefault [ "192.168.1.254" ];
  networking.search = lib.mkDefault [ "lan" ];
}
