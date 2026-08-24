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
    # Register each instance under the hostname it sends in its DHCP request, not
    # the Incus instance name (`managed`, the default).  `dynamic` lets the guest
    # own its `.<domain>` record — so nnh's collector/probe appear as their real
    # hostnames in the zone.
    "dns.mode" = "dynamic";
    # Static A records: `vzhost.${domain}` (the off-DHCP vz-host) PLUS any `staticHosts`
    # the baremetal entry declares (pinned instances whose names must resolve regardless
    # of a DHCP lease — dns.mode=dynamic drops a name when its lease lapses, which stalled
    # the pipeline when akvorado-inlet couldn't resolve nnh-inlet.nikopol after a multi-day
    # offline window; see catalog netplan.baremetal.<host>.staticHosts). Other DHCP clients
    # still auto-register dynamically in the `.${domain}` zone.
    "raw.dnsmasq" = lib.concatStringsSep "\n" (
      [ "host-record=vzhost.${bm.domain},${bm.vzHostAddress}" ]
      ++ lib.mapAttrsToList (name: ip: "host-record=${name}.${bm.domain},${ip}") (bm.staticHosts or { })
    );
  }
  # Confine DHCP to the dynamic sub-segment (the bottom /27) when the baremetal
  # declares a range; the static-high half stays free for reservations (nnh's
  # collector /30 at the top). Without this, dnsmasq auto-ranges the whole /25 and a
  # bare-br recreate can hand a pinned static IP to a DHCP client — which wedged the
  # pipeline (akvorado Kafka + probe stuck on a churned IP). Optional per-baremetal.
  // lib.optionalAttrs (bm ? dhcpRange) {
    "ipv4.dhcp.ranges" = bm.dhcpRange;
  };

  # The config as a JSON manifest (builtins.toJSON — no nix YAML codec needed);
  # the reconcile script parses it with yq-go in JSON-input mode.
  bareBrManifest = pkgs.writeText "bare-br.json" (builtins.toJSON bareBrConfig);

  reconcileScript = ndh.store.installBinScript "incus-bare-br" (
    pkgs.replaceVars ./baremetal-segment.d/incus-bare-br.sh {
      incus = "${pkgs.incus}/bin/incus";
      yq = "${pkgs.yq-go}/bin/yq";
      network = "bare-br";
      manifest = "${bareBrManifest}";
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
      # Invoke bash explicitly (like incus.nix's ExecStartPre): the service's
      # minimal PATH has no `bash`, so the script's `#!/usr/bin/env bash` shebang
      # would fail with exit 127 (`env: 'bash': No such file or directory`).
      ExecStart = "${pkgs.bash}/bin/bash ${reconcileScript}/bin/incus-bare-br";
    };
  };

  # For an off-tailnet corp Mac (hasLink): once this host has provisioned its system
  # keys (ssh-keys-enrichment lands the rotating, CA-signed vz-nudge in systemKeysDir),
  # ship that identity to the corp Mac and (re)load its baremetal-link daemon — so the
  # Mac's WatchPaths link-up.sh can authenticate the guest-reconfigure nudge (see
  # pkgs/baremetal-link.d/). The oneshot runs as root: it reads the 0600 vz-nudge
  # private and connects to the corp Mac as the operator login with the root-readable
  # rdp-host cert (the Mac refuses root ssh). Best-effort + idempotent — the CA cert is
  # long-lived, so a missed/failed run is harmless (the last shipped key keeps working);
  # attached to the contributed target so it re-runs each activation, re-shipping the
  # rotated key.
  systemd.services.baremetal-link-deploy = lib.mkIf hasLink (
    ndhSystemd.attachToContributedTarget {
      description = "Ship vz-nudge + (re)load baremetal-link on the corp Mac (${bm.domain})";
      after = [
        (ndhSystemd.mkServiceName "ssh-keys-enrichment")
        "incus-bare-br.service"
        "network-online.target"
      ];
      wants = [
        (ndhSystemd.mkServiceName "ssh-keys-enrichment")
        "network-online.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        # Invoke bash explicitly (like incus-bare-br above): the service's minimal
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

  networking.firewall.trustedInterfaces = [ "bare-br" ];
  networking.networkmanager.unmanaged = [ "interface-name:bare-br" ];

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

  # Public-internet egress for the bare-br instances.  The managed network keeps
  # `ipv4.nat = false` (source IPs must survive for nnh's flow attribution), so a
  # blanket masquerade is wrong — it would rewrite the source of tailnet/LAN flows
  # too and blind the collector.  Instead masquerade ONLY public-bound egress:
  # traffic whose destination is NOT a private or tailnet range.  A packet to the
  # internet then leaves with the host's LAN address (so the home router can route
  # the reply back), while traffic to the tailnet (${netplan.tailnet.cidr}), the
  # LAN, vzhost.${bm.domain} and other instances keeps its real source.  Own nftables
  # table (firewall.enable is off here), alongside mss-clamp.
  networking.nftables.tables.baremetal-nat = {
    family = "inet";
    content = ''
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr ${bm.netCidr} ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, ${netplan.tailnet.cidr} } masquerade
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
