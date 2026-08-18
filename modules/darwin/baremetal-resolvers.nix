{
  lib,
  ndh,
  ...
}:
# Scoped macOS resolvers for the per-baremetal DNS domains.  Each baremetal host
# owns an Incus segment with a dnsmasq `.<domain>` zone (vzhost.<domain> + the
# instances), advertised into the tailnet.  macOS resolves a split-horizon
# domain ONLY via a scoped `/etc/resolver/<domain>` file — the flat global
# nameserver list never routes it (a public resolver answers NXDOMAIN, a
# definitive negative, so there is no failover).  So point each `<domain>`
# straight at its segment's dnsmasq gateway (catalog `netGateway`), exactly like
# `/etc/resolver/lan` → the LAN DNS.  A single split (not via 100.100.100.100):
# reachability rides the advertised subnet route this host already accepts, and
# general internet DNS is untouched (only the baremetal domains are scoped).
let
  baremetal = ndh.context.catalog.netplan.baremetal or { };
in
{
  environment.etc = lib.mapAttrs' (
    _: bm:
    lib.nameValuePair "resolver/${bm.domain}" {
      text = ''
        # Split-DNS for the ${bm.domain} baremetal segment (vzhost.${bm.domain} + instances).
        # Resolves via the segment's Incus dnsmasq, reached over the advertised subnet route.
        nameserver ${bm.netGateway}
      '';
    }
  ) baremetal;
}
