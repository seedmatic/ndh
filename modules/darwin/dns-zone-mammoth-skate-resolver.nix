# Darwin-only: tell macOS's resolver to send `*.mammoth-skate.test`
# queries to the local dnsmasq.  Common module
# `dns-zone-mammoth-skate.nix` renders the zone records and dnsmasq
# config; this module wires the platform's "send queries for this
# domain to that server" mechanism.
#
# macOS reads `/etc/resolver/<domain>` files (man resolver(5)) — not
# `/etc/resolv.conf` — for per-domain overrides.  Each file is one
# resolver entry; `nameserver 127.0.0.1` here means "send queries
# matching `*.mammoth-skate.test` to localhost:53", which is where
# our dnsmasq is bound (see modules/.common.d/dnsmasq.nix).
#
# The NixOS analogue would be `services.resolved` configuration on
# guests that want to consume the zone — not added yet because all
# our NixOS guests today are Tart guests on bioskop and bioskop
# itself answers their queries via the LAN.
{
  config,
  lib,
  ...
}:
let
  dnsZoneCfg = config.networking.dnsZoneMammothSkateTest;
  zone = config._module.specialArgs.ndh.context.catalog.netplan.lan.zone or "";
in
{
  config = lib.mkIf (dnsZoneCfg.enable && zone != "") {
    environment.etc."resolver/${zone}".text = ''
      # DNS resolver configuration for the closed-world
      # ${zone} zone served by bioskop's dnsmasq on
      # 127.0.0.1:53 (see modules/.common.d/dns-zone-mammoth-skate.nix).
      nameserver 127.0.0.1
    '';
  };
}
