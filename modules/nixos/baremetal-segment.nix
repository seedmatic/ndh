{
  config,
  pkgs,
  lib,
  ndh,
  self,
  ndhSystemd,
  ...
}:
# Per-baremetal instance segment for a NixOS Incus host.  Any host whose
# canonical name matches a `catalog.netplan.baremetal.<name>` entry (nikopol,
# bioskop) becomes the Incus host + subnet router for that segment: a `fabric-br`
# /21 bridge owned by systemd-networkd, its `.<domain>` zone and DHCP served by
# this host's own dnsmasq (static host-records for the off-DHCP vz-host and for
# the NixOS host itself), advertised into the tailnet with split-DNS, and — for a
# host whose entry declares a `linkCidr` (an off-tailnet corp Mac reached over a
# /30) — the static /30 link end on lan-br.  Hosts with no baremetal entry
# (bringup, nerd-nixos) get nothing.  Addresses derive from the catalog — never
# hardcoded.  Incus does NOT manage this bridge; instances attach to it as an
# unmanaged parent, which is what lets each bare-metal keep its own subnet once
# the Incus daemons are clustered (see the ownership note below).
# See catalog/default.nix (netplan.baremetal) and docs/network-topology-c4.adoc.
let
  ndhContext = ndh.context;
  netplan = ndhContext.catalog.netplan or { };
  hostProfile = config.profile.host;
  effectiveHostName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;

  bm = netplan.baremetal.${effectiveHostName} or null;
  enabled = bm != null;
  hasLink = enabled && bm ? linkCidr;
  # A FOREIGN vz-host runs neither nix nor tailscale, so this host is the one that must ship
  # it its link daemon and its nudge identity over ssh.  A nix-managed vz-host installs the
  # same script from its OWN darwin activation (modules/darwin/baremetal-link.nix) and has no
  # deploy package at all — so this must not be merely "has a /30".
  deliversLink = hasLink && bm.vzHostKind == "foreign";

  netPrefix = lib.last (lib.splitString "/" bm.netCidr);
  linkPrefix = lib.last (lib.splitString "/" bm.linkCidr);

  # IPv4 CIDR containment.  Hand-written because `lib.network` in this nixpkgs carries only
  # `ipv6`.  Used to answer ONE question: which published segments live inside this
  # bare-metal's managed net, and therefore whose hosts this dnsmasq must serve.
  ipv4ToInt =
    ip:
    let
      o = map lib.toInt (lib.splitString "." ip);
    in
    (builtins.elemAt o 0) * 16777216
    + (builtins.elemAt o 1) * 65536
    + (builtins.elemAt o 2) * 256
    + (builtins.elemAt o 3);
  pow2 = n: builtins.foldl' (a: _: a * 2) 1 (lib.range 1 n);
  parseCidr =
    c:
    let
      p = lib.splitString "/" c;
    in
    {
      addr = ipv4ToInt (builtins.head p);
      len = lib.toInt (lib.last p);
    };
  # `netplan.segments` is MIXED-FAMILY — it carries fc00::/7, fe80::/10 and the ULA mirror
  # alongside the v4 spans — so the family test comes first, or parsing throws on a v6 address.
  isIpv4Cidr =
    c:
    let
      p = lib.splitString "/" c;
    in
    builtins.length p == 2 && builtins.length (lib.splitString "." (builtins.head p)) == 4;

  # Is `sub` contained in `outer` (equality counts)?  The length test is load-bearing: without
  # it a SHORTER prefix sharing the same network address — say a /24 against a /25 — would
  # compare equal once masked and be wrongly judged inside.
  cidrWithin =
    outer: sub:
    let
      o = parseCidr outer;
      s = parseCidr sub;
      mask = 4294967296 - pow2 (32 - o.len);
    in
    isIpv4Cidr sub && s.len >= o.len && builtins.bitAnd s.addr mask == builtins.bitAnd o.addr mask;

  # The static A records this segment's dnsmasq serves, DERIVED from the published segments
  # rather than restated.  `dns.mode=dynamic` only registers a name while its lease lives, so a
  # pinned instance loses its name during a long offline window — which is how akvorado-inlet
  # came to be unable to resolve its own Kafka broker (nnh-inlet.nikopol) after a multi-day gap,
  # stalling the pipeline. Static records make those names independent of DHCP.
  #
  # The source is `netplan.segments`, whose `hosts` the catalog merge concatenates by cidr: ndh
  # contributes `vzhost.<domain>` on the managed net, and a tenant (nnh) contributes its own
  # pinned hosts on the sub-segment it owns. Selecting by CONTAINMENT rather than by an exact
  # cidr match is what makes the tenant's hosts visible at all — they sit on a /30 inside the
  # /25, so a match on `bm.netCidr` alone would never see them.
  #
  # A name is qualified with the zone only when it carries no dot: ndh publishes `vzhost.<domain>`
  # already qualified (the segment list is also read for flow attribution, where a bare `vzhost`
  # would be ambiguous across bare-metals), while a tenant publishes bare instance names.
  segmentHostRecords = lib.concatMap (
    seg: if cidrWithin bm.netCidr seg.cidr then seg.hosts or [ ] else [ ]
  ) (netplan.segments or [ ]);
  qualify = name: if lib.hasInfix "." name then name else "${name}.${bm.domain}";

  # The dotted netmask dnsmasq wants in `dhcp-range` (it takes a mask, not a prefix length).
  # Integer division truncates in Nix, which is what makes the octet extraction work.
  intToIpv4 =
    n:
    lib.concatStringsSep "." (
      map toString [
        (n / 16777216)
        ((n / 65536) - (n / 16777216) * 256)
        ((n / 256) - (n / 65536) * 256)
        (n - (n / 256) * 256)
      ]
    );
  netNetmask = intToIpv4 (4294967296 - pow2 (32 - lib.toInt netPrefix));

  # Static records, split by whether the host pins a hwaddr.  A host that carries a `mac` becomes
  # a `dhcp-host` RESERVATION — the one directive does both jobs, pinning the address to that
  # hwaddr AND answering the name.  A MAC-less host gets the name only: nothing binds it to an
  # address, so asserting one would be a record nothing ever answers on.
  #
  # This is the door through which rke2lab's cluster-node reservations arrive. They used to be
  # rows on the home router, declared in this catalog's `netplan.lan.hosts` and reconciled against
  # the bbox; rke2lab moved its nodes into the fabric, so the reservations moved to the authority
  # that owns the network they now live on — this dnsmasq. Same information, and now address and
  # name are served by ONE thing instead of the bbox plus avahi, which is the split that made an
  # mDNS name necessary at all.
  pinnedHosts = builtins.filter (h: (h.mac or null) != null) segmentHostRecords;
  namedHosts = builtins.filter (h: (h.mac or null) == null) segmentHostRecords;

  # DHCP confined to the dynamic sub-segment (the bottom /27) when the baremetal declares a range;
  # the static-high half stays free for reservations (nnh's collector /30 at the top). Without the
  # confinement dnsmasq auto-ranges the whole net and can hand a pinned static address to a DHCP
  # client — which wedged the pipeline once (akvorado Kafka + probe stuck on a churned IP).
  # The catalog spells the range incus-style (`start-end`); dnsmasq wants `start,end,mask,lease`.
  dhcpRangeParts = lib.splitString "-" bm.dhcpRange;
  dhcpRangeSetting = "${builtins.head dhcpRangeParts},${lib.last dhcpRangeParts},${netNetmask},${dhcpLease}";
  dhcpLease = "1h";
in
lib.mkIf enabled {
  # ONE OWNER for this network, and it is now NIXOS — systemd-networkd owns the bridge,
  # `services.dnsmasq` owns the addressing and the zone.  Incus knows nothing about `fabric-br`:
  # instances attach to it as an UNMANAGED parent bridge (`nictype=bridged, parent=fabric-br`),
  # which is already how rke2lab attaches them — its `ensureNetwork` explicitly skips this name as
  # "the canonical host-provided bridge".
  #
  # Why the ownership moved off Incus. A CLUSTERED Incus requires that "all members of a cluster
  # must have identical networks defined": only `bridge.external_interfaces`, `parent`,
  # `bgp.ipv4.nexthop` and `bgp.ipv6.nexthop` may differ per member — `ipv4.address` may NOT. Our
  # fabric subnets differ BY DESIGN (one routed slice per bare-metal, each advertised into the
  # tailnet) and so do the zones (`.bioskop` / `.nikopol`). As an Incus-managed network that is
  # unrepresentable in a cluster; as a host bridge it is just a NAME that resolves locally on each
  # member, so everything cluster-wide referring to `fabric-br` keeps working unchanged.
  #
  # Two things fall out for free, independent of clustering:
  #
  # * the create-vs-reconcile race is GONE with its oneshot. That race was real, measured on both
  #   bare-metals 2026-09-24: `incus admin init --preseed` runs on EVERY activation (it is not
  #   create-only, as had been assumed) and fails when a declared network already exists —
  #   "Failed to create local member network \"fabric-br\": Network \"fabric-br\" already exists" —
  #   taking `switch-to-configuration` to exit 4. Ordering `After = incus-preseed.service` did not
  #   fix it either, because `switch-to-configuration` starts new and restarts changed units in
  #   SEPARATE systemctl invocations, so `After` — which orders within one transaction — never
  #   applied. With no Incus object there is no second creator to race.
  # * `no-hosts` below closes a trap this zone was exposed to: Incus's dnsmasq served the HOST's
  #   `/etc/hosts`, where NixOS writes `127.0.0.2 <hostname>`, so a client asking for the bare host
  #   name got the asker's own loopback back ("certificate is valid for localhost"). Declaring the
  #   zone ourselves lets us refuse to serve that file at all.

  systemd.network.netdevs."40-fabric-br".netdevConfig = {
    Name = "fabric-br";
    Kind = "bridge";
  };

  systemd.network.networks."40-fabric-br" = {
    matchConfig.Name = "fabric-br";
    address = [ "${bm.netGateway}/${netPrefix}" ];
    networkConfig = {
      # A bridge with no member has NO CARRIER, and networkd withholds addresses from a
      # carrier-less link — so without this the gateway address (and with it dnsmasq's bind
      # target) would appear only once the first instance plugged in, which is exactly backwards:
      # the instance needs DHCP to come up. This bridge does sit memberless — measured
      # `used_by: []`, link DOWN on bioskop.
      ConfigureWithoutCarrier = true;
      # The Incus network this replaces carried `ipv6.address = none`; keep the plane v4-only
      # rather than acquire a link-local the addressing plan does not describe.
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
    };
  };

  # The zone's authority: DHCP + DNS for this bare-metal's slice, and nothing else.
  services.dnsmasq = {
    enable = true;
    # Do NOT become the host's resolver. The host resolves through its own path (tailnet / home
    # LAN); this daemon exists for the instances on the bridge, and for the tailnet peers that
    # reach the `.<domain>` zone through the advertised route + split-DNS.
    resolveLocalQueries = false;
    settings = {
      # Bind ONLY the bridge, so nothing here competes with the host's resolver stack.
      interface = [ "fabric-br" ];
      bind-interfaces = true;
      # Never serve the host's /etc/hosts — see the rationale above.
      no-hosts = true;
      # The zone. `local` makes this daemon authoritative for it, so a miss answers NXDOMAIN here
      # instead of leaking the query upstream to a resolver that cannot know the answer.
      domain = bm.domain;
      local = "/${bm.domain}/";
      # Register a DHCP client under the hostname IT sends, qualified into the zone — the property
      # Incus spelled `dns.mode = dynamic`, and the reason a tenant's collector/probe appear under
      # their real names rather than under an instance name.
      expand-hosts = true;
      dhcp-authoritative = true;
      dhcp-range = [ dhcpRangeSetting ];
      dhcp-host = map (h: "${h.mac},${qualify h.name},${h.ip}") pinnedHosts;
      host-record = map (h: "${qualify h.name},${h.ip}") namedHosts;
    };
  };

  # For a FOREIGN vz-host (deliversLink): once this host has provisioned its system
  # keys (ssh-keys-enrichment lands the rotating, CA-signed vz-nudge in systemKeysDir),
  # ship that identity to the corp Mac and (re)load its baremetal-link daemon — so the
  # Mac's WatchPaths link-up.sh can authenticate the guest-reconfigure nudge (see
  # pkgs/baremetal-link.d/). The oneshot runs as root: it reads the 0600 vz-nudge
  # private and connects to the corp Mac as the operator login with the root-readable
  # rdp-host cert (the Mac refuses root ssh). Best-effort + idempotent — the CA cert is
  # long-lived, so a missed/failed run is harmless (the last shipped key keeps working);
  # attached to the contributed target so it re-runs each activation, re-shipping the
  # rotated key.
  systemd.services.baremetal-link-deploy = lib.mkIf deliversLink (
    ndhSystemd.attachToContributedTarget {
      description = "Ship vz-nudge + (re)load baremetal-link on the corp Mac (${bm.domain})";
      # No fabric-br ordering: the deploy reaches the vz-host over the /30 on lan-br, never over
      # the fabric.
      after = [
        (ndhSystemd.mkServiceName "ssh-keys-enrichment")
        "network-online.target"
      ];
      wants = [
        (ndhSystemd.mkServiceName "ssh-keys-enrichment")
        "network-online.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        # Invoke bash explicitly (as incus.nix's ExecStartPre does): the service's minimal
        # PATH has no `bash`, so the deploy bin's `#!/usr/bin/env -S bash` shebang
        # fails with exit 127 (`env: 'bash': No such file or directory`).
        ExecStart =
          let
            deploy = self.packages.${pkgs.stdenv.hostPlatform.system}."${bm.domain}-baremetal-link-deploy";
          in
          "${pkgs.bash}/bin/bash ${deploy}/bin/${bm.domain}-baremetal-link-deploy";
      };
    }
  );

  networking.firewall.trustedInterfaces = [ "fabric-br" ];
  networking.networkmanager.unmanaged = [ "interface-name:fabric-br" ];

  # Advertise this baremetal segment's aggregate into the tailnet, so peers reach
  # the instances and the vz-host by name (paired with the split-DNS `.<domain>`
  # zone → this host's dnsmasq).  On the Tailscale SaaS controller the route still
  # needs console approval + the split-DNS nameserver entry (runtime); both become
  # declarative once Headscale is the live control-plane.  Dormant if the headscale
  # client is disabled on this host.
  #
  # A LAN-fixed baremetal (the always-on Mac Mini, `lanAttachment = "fixed"`) is
  # additionally the subnet router for the whole home LAN, so peers reach every
  # device on it (including vzhost.<host> at its LAN address).  A roaming host (corp
  # MacBook) must NOT advertise it — the route would follow the laptop off-site.
  # Only ONE fixed host per LAN may advertise `netplan.lan.cidr` (two routers for
  # the same CIDR would collide).
  networking.headscale.advertiseRoutes = [
    bm.advertiseCidr
  ]
  ++ lib.optional ((bm.lanAttachment or "roaming") == "fixed") netplan.lan.cidr;

  # This host is a subnet router for its fabric-br /21 (advertised into the tailnet):
  # forward between fabric-br and the tailnet, and clamp forwarded TCP MSS to the
  # per-route MTU.  fabric-br/lan-br are 1500-MTU, tailscale0 is 1280 — an instance ↔
  # tailnet peer SYN crosses that step and would blackhole on PMTUD (DF set, ICMP
  # frag-needed often filtered) without the clamp.  `size set rt mtu` rewrites the
  # SYN MSS to the egress-route MTU per flow (intra-1500 stays 1460, tailnet-bound
  # drops to 1240).  firewall.enable is off here, so this is its own nftables table.
  boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;
  networking.nftables.tables.mss-clamp = {
    family = "inet";
    content = ''
      chain forward {
        type filter hook forward priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu
      }
    '';
  };

  # Public-internet egress for everything behind this bare-metal.  The managed network keeps
  # `ipv4.nat = false` (source IPs must survive for nnh's flow attribution), so a
  # blanket masquerade is wrong — it would rewrite the source of tailnet/LAN flows
  # too and blind the collector.  Instead masquerade ONLY public-bound egress:
  # traffic whose destination is NOT a private or tailnet range.  A packet to the
  # internet then leaves with the host's LAN address (so the home router can route
  # the reply back), while traffic to the tailnet (${netplan.tailnet.cidr}), the
  # LAN, vzhost.${bm.domain} and other instances keeps its real source.  Own nftables
  # table (firewall.enable is off here), alongside mss-clamp.
  #
  # The source is the whole SLICE (`advertiseCidr`), not the fabric-br half (`netCidr`),
  # because the slice is this bare-metal's unit of ownership — that is exactly what it
  # advertises into the tailnet. Scoping to the /21 covered the fabric-br tenants and left
  # every slot at offset >= 8 out: correct today, since the only one in use is the
  # vz-host /30 whose far end is a Mac with its own default route, but a silent hole for
  # slots 9-15. An unmasqueraded public-bound packet is not refused, it BLACKHOLES, so
  # the failure would arrive with no signal. Widening costs nothing: the destination
  # exclusions are unchanged, so private and tailnet flows still carry real sources, and
  # a vz-host that ever did route public traffic through this host would WANT the
  # masquerade rather than be harmed by it.
  networking.nftables.tables.baremetal-nat = {
    family = "inet";
    content = ''
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr ${bm.advertiseCidr} ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, ${netplan.tailnet.cidr} } masquerade
      }
    '';
  };

  # Static /30 link end toward an off-tailnet corp Mac — only for a host whose
  # baremetal entry declares a `linkCidr`.  A secondary address on lan-br
  # (systemd-networkd-managed); DHCP on lan-br still provides the LAN lease.
  systemd.network.networks."40-lan-br".address = lib.optionals hasLink [
    "${bm.hostAddress}/${linkPrefix}"
  ];
}
