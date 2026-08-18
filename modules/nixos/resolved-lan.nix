{ lib, ndh, ... }:
let
  # Single source: the LAN gateway (home router DNS) and domain come from the
  # catalog — never re-typed here.  `domain` is the dotted `.lan`; resolved wants
  # the bare label.
  lan = ndh.context.catalog.netplan.lan;
  lanDomain = lib.removePrefix "." lan.domain;
in
{
  # Prefer the home router DNS on the primary LAN link (enp0s1) instead of public resolvers.
  # Uses mkDefault so host-specific configs can override if needed. (@codebase)
  services.resolved = {
    enable = lib.mkDefault true;
    # extraConfig was removed in 26.05 — resolved.conf is now built from
    # settings.Resolve (the old fallbackDns/domains/llmnr options are aliases into it).
    settings.Resolve = {
      DNS = lib.mkDefault lan.gateway;
      FallbackDNS = lib.mkDefault "";
      Domains = lib.mkDefault lanDomain;
      MulticastDNS = lib.mkDefault "yes";
      LLMNR = lib.mkDefault "no";
    };
  };

  # Keep networking.nameservers aligned with resolved.
  networking.nameservers = lib.mkDefault [ lan.gateway ];
  networking.search = lib.mkDefault [ lanDomain ];
}
