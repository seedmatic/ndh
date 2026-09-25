{
  config,
  lib,
  ndh,
  ...
}:
# The per-cluster `vmnet-<role>` provisioning bridges a NixOS Incus host carries.
#
# Distinct from modules/nixos/baremetal-segment.nix on purpose: that module owns this BARE-METAL's
# own segment — its `/21` fabric slice, its `.<domain>` zone, the `/30` link to the vz-host, its
# subnet-router role.  These bridges are per-CLUSTER planes, addressed from rke2lab's `10.80/18`
# cluster carve rather than from the bare-metal's slice, with their own source in the blueprint and
# their own lifecycle.  Same host, different authority.
#
# Why they live here at all, rather than in Incus.  A clustered Incus requires that "all members of
# a cluster must have identical networks defined" and `ipv4.address` may not differ per member,
# while these differ per cluster BY DESIGN.  Worse than unrepresentable: a cluster-wide managed
# network is materialised on EVERY member, so this host would hold a bridge carrying the other
# bare-metal's `/21` and route the cross-host cluster reach into a dead interface.  And the
# collision cannot be renamed away — `vmnet-<host>-<role>` exceeds the 15 characters Incus and
# `IFNAMSIZ` both stop at.  A host bridge has no such constraint: the same name may mean a different
# subnet on each machine, exactly as `fabric-br` now does.
#
# Incus keeps attaching instances to them by `parent` (`nictype=bridged`), which is already how
# rke2lab attaches — it never referenced these as `network=`.
let
  netplan = ndh.context.catalog.netplan or { };
  hostProfile = config.profile.host;
  effectiveHostName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;

  bm = netplan.baremetal.${effectiveHostName} or null;

  # Derived from rke2lab's `<domain>-<role>-net` segments rather than restated: the blueprint owns
  # the addressing.  The set is CLOSED (two roles per bare-metal), so declaring them statically
  # costs no flexibility — and a bridge whose cluster does not exist yet simply sits memberless,
  # which fabric-br already proves is harmless.
  pattern = "^${bm.domain}-([a-z]+)-net$";
  roleOf = seg: builtins.head (builtins.match pattern seg.name);
  # ⚠️ The pattern alone is not enough: `<domain>-baremetal-net` matches it too — that is ndh's OWN
  # segment, the bare-metal's `/21` fabric slice that baremetal-segment.nix owns, and it carries no
  # DHCP range. Excluding the role by name says which module owns what, rather than inferring it
  # from which keys happen to be present.
  #
  # Short-circuit on a host with no baremetal entry (bringup, nerd-nixos): `pattern` dereferences
  # `bm.domain`, so filtering unguarded would throw there rather than yield nothing.
  segments =
    if bm == null then
      [ ]
    else
      builtins.filter (
        seg: builtins.match pattern (seg.name or "") != null && roleOf seg != "baremetal"
      ) (netplan.segments or [ ]);

  enabled = segments != [ ];

  # `vmnet-<role>` — the SAME name rke2lab derives (`"vmnet-" + role`), so the `parent` its instance
  # NICs carry keeps resolving with nothing to change on that side.
  bridgeOf = seg: "vmnet-${builtins.head (builtins.match pattern seg.name)}";

  addrOf = cidr: builtins.head (lib.splitString "/" cidr);
  prefixOf = cidr: lib.toInt (lib.last (lib.splitString "/" cidr));

  pow2 = n: builtins.foldl' (a: _: a * 2) 1 (lib.range 1 n);
  # Integer division truncates in Nix, which is what makes the octet extraction work.
  netmaskOf =
    len:
    let
      n = 4294967296 - pow2 (32 - len);
    in
    lib.concatStringsSep "." (
      map toString [
        (n / 16777216)
        ((n / 65536) - (n / 16777216) * 256)
        ((n / 256) - (n / 65536) * 256)
        (n - (n / 256) * 256)
      ]
    );

  lease = "1h";

  # The v4 pool the CAPN-provisioned cattle nodes draw from.  Pets hold reservations below; cattle
  # cannot — the provider mints their hwaddr, so nothing can reserve for them.  The blueprint spells
  # the range incus-style (`start-end`); dnsmasq wants `start,end,mask,lease`.
  range4 =
    seg:
    let
      parts = lib.splitString "-" seg.dhcp;
    in
    "${builtins.head parts},${lib.last parts},${netmaskOf (prefixOf seg.cidr)},${lease}";

  # The /64's first four groups. The blueprint emits cidr6 uncompressed
  # (`fd96:6924:3693:20:0:0:0:0/64`), so the first four groups ARE the prefix.
  prefix6 = seg: lib.concatStringsSep ":" (lib.take 4 (lib.splitString ":" (addrOf seg.cidr6)));

  # STATEFUL DHCPv6, not SLAAC: a node's address must be the one `node-ip` names, and SLAAC would
  # hand out an EUI-64 address instead.  The window is chosen by a RULE, not picked — every reserved
  # node address embeds its v4 verbatim in the low 32 bits (`10.80.0.10` → `::0a50:000a`), so the
  # reservations all live in `::0a50:0000`–`::0a53:ffff`.  A pool at `::ff:0`–`::ff:ffff` is
  # therefore provably disjoint from them, for every cluster.
  range6 = seg: "${prefix6 seg}::ff:0,${prefix6 seg}::ff:ffff,64,${lease}";

  # Dual-stack reservations, and deliberately NAMELESS.  Incus ran these bridges with
  # `dns.mode = none` — the vmnet plane carries no DNS.  The one dnsmasq on this host serves the
  # `.<domain>` zone for the fabric, so naming a reservation here would publish a SECOND A record
  # for a name the fabric already claims (`<cluster>-<node>` resolves to its FABRIC address): two
  # answers for one name.  Address-only keeps the two planes separate, as they were.
  reservations =
    seg:
    map (h: "${h.mac},${h.ip},[${h.ip6}]") (
      builtins.filter (h: (h.mac or null) != null) (seg.hosts or [ ])
    );

  bridges = map bridgeOf segments;
in
lib.mkIf enabled {
  # One netdev + one network per cluster plane. `ConfigureWithoutCarrier` for the same reason
  # fabric-br needs it: a memberless bridge has NO CARRIER and networkd would withhold the address,
  # so the gateway — and with it dnsmasq's bind target — would appear only once the first instance
  # plugged in, which is backwards since that instance needs DHCP to come up.
  #
  # IPv6 link-local is KEPT here (unlike fabric-br, which is v4-only): DHCPv6 and the router
  # advertisements that tell a client to use it both ride it.
  systemd.network.netdevs = lib.listToAttrs (
    map (
      seg:
      lib.nameValuePair "40-${bridgeOf seg}" {
        netdevConfig = {
          Name = bridgeOf seg;
          Kind = "bridge";
        };
      }
    ) segments
  );

  systemd.network.networks = lib.listToAttrs (
    map (
      seg:
      lib.nameValuePair "40-${bridgeOf seg}" {
        matchConfig.Name = bridgeOf seg;
        address = [
          "${seg.gateway}/${toString (prefixOf seg.cidr)}"
          "${seg.gateway6}/${toString (prefixOf seg.cidr6)}"
        ];
        networkConfig = {
          ConfigureWithoutCarrier = true;
          # We are the router on this plane, not a client — dnsmasq sends the RAs, not networkd.
          IPv6AcceptRA = false;
        };
      }
    ) segments
  );

  # Contributed to the host's ONE dnsmasq rather than run as a second daemon. Two modules writing
  # one service is not the single-owner problem — that rule is about two CONTROLLERS racing at
  # runtime; these are declarative definitions the module system merges deterministically.
  services.dnsmasq.settings = {
    interface = bridges;
    dhcp-range = lib.concatMap (seg: [
      (range4 seg)
      (range6 seg)
    ]) segments;
    dhcp-host = lib.concatMap reservations segments;
    # Without RAs a client never learns it should ask for a stateful DHCPv6 lease. Harmless for
    # fabric-br, which has no v6 range for dnsmasq to advertise.
    enable-ra = true;
  };

  networking.firewall.trustedInterfaces = bridges;
  networking.networkmanager.unmanaged = map (b: "interface-name:${b}") bridges;
}
