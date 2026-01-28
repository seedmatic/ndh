{ lib, ... }:
{
  # Prefer the home router DNS on the primary LAN link (enp0s1) instead of public resolvers.
  # Uses mkDefault so host-specific configs can override if needed. (@codebase)
  services.resolved = {
    enable = lib.mkDefault true;
    extraConfig = lib.mkDefault ''
      DNS=192.168.1.254
      FallbackDNS=
      Domains=lan
      MulticastDNS=yes
      LLMNR=yes
    '';
  };

  # Keep networking.nameservers aligned with resolved.
  networking.nameservers = lib.mkDefault [ "192.168.1.254" ];
  networking.search = lib.mkDefault [ "lan" ];
}
