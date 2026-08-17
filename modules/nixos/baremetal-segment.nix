{
  config,
  pkgs,
  lib,
  ndh,
  ...
}:
# Per-baremetal instance segment for a NixOS Incus host.  Any host whose
# canonical name matches a `catalog.netplan.baremetal.<name>` entry (nikopol,
# bioskop) becomes the Incus host + subnet router for that segment: a managed
# `bare-br` /25 (Incus dnsmasq, `.<domain>` zone, a static host-record for the
# off-DHCP vz-host) advertised into the tailnet with split-DNS, and — for a host
# whose entry declares a `linkCidr` (an off-tailnet corp Mac reached over a /30) —
# the static /30 link end on lan-br.  Hosts with no baremetal entry (bringup,
# nerd-nixos) get nothing.  Addresses derive from the catalog — never hardcoded.
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

  netPrefix = lib.last (lib.splitString "/" bm.netCidr);
  linkPrefix = lib.last (lib.splitString "/" bm.linkCidr);

  # bare-br managed-network config — the single source for BOTH belts (preseed +
  # reconcile), so the two cannot drift.
  bareBrConfig = {
    "ipv4.address" = "${bm.netGateway}/${netPrefix}";
    "ipv4.nat" = "false";
    "ipv4.dhcp" = "true";
    "ipv6.address" = "none";
    "dns.domain" = bm.domain;
    # Static A record so `vz.${domain}` resolves to the vz-host (a corp Mac at its
    # /30 address, or an on-tailnet bare-metal at its LAN address) — not a dnsmasq
    # DHCP client.  DHCP clients (nnh collector, other instances) auto-register in
    # the `.${domain}` zone; their addresses are theirs, not the catalog's.
    "raw.dnsmasq" = "host-record=vz.${bm.domain},${bm.vzHostAddress}";
  };

  reconcileScript = ndh.store.installBinScript "incus-bare-br" (
    pkgs.replaceVars ./baremetal-segment.d/incus-bare-br.sh {
      incus = "${pkgs.incus}/bin/incus";
      network = "bare-br";
      keyvals = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (key: value: "${key}\t${value}") bareBrConfig
      );
    }
  );
in
lib.mkIf enabled {
  # DOUBLE BELT.  The nixpkgs incus preseed is CREATE-ONLY and runs once at
  # `incus init`, so on an already-initialised incus adding bare-br here is
  # silently ignored — and it never reconciles later field changes.  So we keep
  # the preseed (fresh bringup) AND add the reconcile oneshot below (existing
  # incus + drift).  Both read the one bareBrConfig.  List options merge across
  # modules, so this unions with modules/nixos/incus.nix's empty preseed.networks.
  virtualisation.incus.preseed.networks = [
    {
      name = "bare-br";
      type = "bridge";
      config = bareBrConfig;
    }
  ];

  systemd.services.incus-bare-br = {
    description = "Reconcile the bare-br Incus network (preseed is create-only)";
    after = [ "incus.service" ];
    requires = [ "incus.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${reconcileScript}/bin/incus-bare-br";
    };
  };

  networking.firewall.trustedInterfaces = [ "bare-br" ];
  networking.networkmanager.unmanaged = [ "interface-name:bare-br" ];

  # Advertise this baremetal segment's aggregate into the tailnet, so peers reach
  # the instances and the vz-host by name (paired with the split-DNS `.<domain>`
  # zone → this host's dnsmasq).  On the Tailscale SaaS controller the route still
  # needs console approval + the split-DNS nameserver entry (runtime); both become
  # declarative once Headscale is the live control-plane.  Dormant if the headscale
  # client is disabled on this host.
  networking.headscale.advertiseRoutes = [ bm.advertiseCidr ];

  # This host is a subnet router for its bare-br /25 (advertised into the tailnet):
  # forward between bare-br and the tailnet, and clamp forwarded TCP MSS to the
  # per-route MTU.  bare-br/lan-br are 1500-MTU, tailscale0 is 1280 — an instance ↔
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

  # Static /30 link end toward an off-tailnet corp Mac — only for a host whose
  # baremetal entry declares a `linkCidr`.  A secondary address on lan-br
  # (systemd-networkd-managed); DHCP on lan-br still provides the LAN lease.
  systemd.network.networks."40-lan-br".address = lib.optionals hasLink [
    "${bm.hostAddress}/${linkPrefix}"
  ];
}
