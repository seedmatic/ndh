{ cacheTrust, networkBlueprint }:
{
  caches = cacheTrust.caches;

  # Tailnet control-plane identity: shared tag vocabulary + ACL policy
  # (both controllers) + headscale server specifics.  See
  # catalog/tailnet/default.nix.
  tailnet = import ./tailnet;

  # v2 has a single OS user; the catalog holds it directly without the
  # former per-profile wrapper.
  user = {
    name = "nxmatic";
    description = "Stephane Lacoin (aka nxmatic)";
    email = "stephane.lacoin@gmail.com";
  };

  netplan =
    let
      # Per-baremetal instance segments: each baremetal host owns an Incus segment +
      # dnsmasq DNS domain, advertised into the tailnet so peers resolve
      # <inst>.<domain> via the segment's dnsmasq and reach it — including the
      # off-tailnet corp Mac vz.nikopol, reached over a static /30 via its Incus host.
      # SINGLE SOURCE for the corp-Mac package (Darwin) and the Incus host (NixOS):
      # .253/.254/the CIDRs derive from here, never hard-coded twice.  On the Tailscale
      # SaaS controller (current) the advertise + split-DNS are applied at runtime in
      # the console; they become declarative (Headscale daemon dns.split) once Headscale
      # is the live control-plane.  See docs/network-topology-c4.adoc.
      baremetal = {
        # nikopol: the vz-host is a CORPORATE Mac that cannot join the tailnet — so its
        # vz.<host> lives at .253 on a static /30 link to the Incus host, reached only via
        # the advertised segment.  `linkCidr`/`hostAddress` are the /30 endpoints.
        nikopol = {
          domain = "nikopol";
          netCidr = "172.16.6.0/25"; # managed Incus net (dnsmasq) — netflow instances
          netGateway = "172.16.6.1"; # Incus bridge + dnsmasq + split-DNS target
          linkCidr = "172.16.6.252/30"; # static P2P link: corp Mac <-> Incus host
          hostAddress = "172.16.6.254"; # nikopol-nixos link end on lan-br (subnet router)
          vzHostAddress = "172.16.6.253"; # corp Mac en0 alias (dnsmasq host-record vz.nikopol)
          advertiseCidr = "172.16.6.0/24"; # aggregate advertised into the tailnet
          lanAttachment = "roaming"; # itinerant (runs on the corp MacBook) — must NOT advertise the home LAN
        };
        # bioskop: the vz-host is a PERSONAL Mac Mini already on the tailnet + home LAN, so
        # vz.bioskop resolves to its real LAN address (.129, reachable via the home-LAN
        # advertise) — NO /30 link, no off-tailnet corp Mac.  The segment exists for
        # uniform .bioskop instance discovery + the vz.bioskop name.
        bioskop = {
          domain = "bioskop";
          netCidr = "172.16.7.0/25"; # managed Incus net (dnsmasq) — bioskop instances
          netGateway = "172.16.7.1"; # Incus bridge + dnsmasq + split-DNS target
          vzHostAddress = "192.168.1.129"; # bioskop bare-metal LAN addr (dnsmasq host-record)
          advertiseCidr = "172.16.7.0/24"; # aggregate advertised into the tailnet
          lanAttachment = "fixed"; # Mac Mini, permanently on the home LAN — this host's subnet router advertises netplan.lan.cidr
        };
      };
    in
    {
      lan = {
        cidr = "192.168.1.0/24";
        domain = ".lan";
        gateway = "192.168.1.254";

        # LAN-side authorities (routers, APs, anything that owns part of
        # the LAN's behaviour).  Non-secret metadata only; the matching
        # admin credential lives sops-encrypted in `.secrets` under the
        # same key (e.g. `lan.mammoth-skate.password`).
        routers = {
          mammoth-skate = {
            # Bouygues Bbox residential router, primary LAN gateway and
            # DHCP server.  Drives:
            #   - DHCP leases + static reservations (see `hosts` below)
            #   - WAN port forwards (see `netplan.wan.portForwards`)
            #   - DDNS publication (see `netplan.wan.ddnsHostname`)
            address = "192.168.1.254";
            adminUrl = "https://mabbox.bytel.fr";
            # API-shape reference: docs/bbox-api.adoc
            kind = "bbox";
          };
        };

        # Static DHCP reservations on `mammoth-skate`.  Source of truth
        # for the catalog; reconciled against the bbox via the
        # `bbox-reconcile` script which reads /api/v1/dhcp/clients and
        # diffs against this map.
        #
        # Tailnet-side DNS for these hosts (when relevant) lives in
        # `tailnet.hosts` below — that's the input to headscale's
        # `dns.extra_records` and the only DNS surface that exists today.
        # The previous `.test` zone served by per-host dnsmasq has been
        # retired (see commits 98c4d9c7+).
        #
        # Schema:
        #   mac    — primary key for bbox reconciliation
        #   ip     — static reservation IP (LAN, not tailnet)
        #   kind   — role for downstream consumers; values:
        #              darwin-host  → top-level RDP-able Mac
        #              nixos        → NixOS guest VM
        #              rke2         → RKE2 cluster member (requires `role`)
        #              wifi-iface   → wifi NIC
        #              vz-host      → corporate bare-metal Mac / its VZ bridge
        #              media        → home A/V device (audio, TV, chromecast)
        #   ownership — who the machine belongs to: `personal` (default) or
        #            `corporate`.  A label for downstream flow attribution (nnh);
        #            orthogonal to reconciliation — ndh reconciles both.
        #   parent — top-level host this entry belongs under (omitted for
        #            top-level hosts themselves).
        #   role   — local label within `kind` (only used by `kind=rke2`
        #            today: master / peer{1,2,3} / worker{1,2}).
        hosts = {
          # bioskop: bare-metal Mac (the daily driver), top-level.
          bioskop = {
            mac = "00:30:93:1d:0e:48";
            ip = "192.168.1.129";
            kind = "darwin-host";
            ownership = "personal";
          };
          bioskop-wifi = {
            mac = "ca:f1:1a:ef:69:9f";
            ip = "192.168.1.158";
            kind = "wifi-iface";
            parent = "bioskop";
            ownership = "personal";
          };
          bioskop-nixos = {
            mac = "10:66:6a:4c:27:01";
            ip = "192.168.1.130";
            kind = "nixos";
            parent = "bioskop";
            ownership = "personal";
          };

          # nikopol: a Tart/VZ macOS guest (the catalog Mac), top-level — the
          # personal environment running on the corporate bare metal (`vz-host`
          # entries below).
          nikopol = {
            mac = "86:b7:a1:96:1a:9f";
            ip = "192.168.1.33";
            kind = "darwin-host";
            ownership = "personal";
          };
          nikopol-nixos = {
            mac = "10:66:6a:4c:d6:01";
            ip = "192.168.1.34";
            kind = "nixos";
            parent = "nikopol";
            ownership = "personal";
          };

          # vz — the corporate bare-metal Mac hosting the nikopol Tart VM, and
          # its VZ-bridge interface.  BOTH carry bbox reservations (the earlier
          # "not on this LAN / no reservation" note was wrong — the router has
          # `nikopol-vzhost` at .1 and `nikopol-vz` at .65).  `corporate`: the
          # hardware + its DHCP are company-governed, but we keep the
          # reservations declared so addressing stays predictive (and portable
          # if the provider changes); ndh reconciles them like any other host.
          nikopol-vzhost = {
            mac = "4a:04:df:ff:a8:de";
            ip = "192.168.1.1";
            kind = "vz-host";
            ownership = "corporate";
          };
          nikopol-vz = {
            mac = "84:2f:57:d4:36:be";
            ip = "192.168.1.65";
            kind = "vz-host";
            ownership = "corporate";
          };

          # Home A/V devices — reserved so their addresses stay predictive.
          # Previously hand-managed and filtered out via
          # lan-ignored-reservations.yaml; now first-class + reconciled.
          zecoute = {
            mac = "00:22:6c:1b:8c:08";
            ip = "192.168.1.5";
            kind = "media";
            ownership = "personal";
          };
          huematic = {
            mac = "00:17:88:2b:22:0d";
            ip = "192.168.1.6";
            kind = "media";
            ownership = "personal";
          };
          pop-screen = {
            mac = "68:fc:ca:31:4d:be";
            ip = "192.168.1.7";
            kind = "media";
            ownership = "personal";
          };
          vertdegris = {
            mac = "00:10:83:08:fe:c6";
            ip = "192.168.1.8";
            kind = "media";
            ownership = "personal";
          };
          pop-cast = {
            mac = "a4:77:33:ee:9e:1e";
            ip = "192.168.1.12";
            kind = "media";
            ownership = "personal";
          };

          # RKE2 cluster members — a pure projection of rke2lab's network
          # blueprint (the single source of truth; see the `networkBlueprint`
          # argument and the rke2lab flake input). Each `${cluster}-${node}` host
          # takes its MAC and LAN IP from `addressing.${cluster}.${node}`, so the
          # `10:66:6a:4c:${clusterId}:${nodeId}` MAC scheme and the bbox static
          # reservations stay in lockstep with rke2lab — no hand-copied values to
          # drift. Naming: {host}-{role} for simpler DNS lookups.
        }
        // (
          let
            addressing = networkBlueprint.addressing;
            # Flatten addressing.${cluster}.${node} into catalog host entries,
            # using only builtins (the catalog has no `lib` in scope).
            rke2HostList = builtins.concatMap (
              cluster:
              map (node: {
                name = "${cluster}-${node}";
                value = {
                  mac = addressing.${cluster}.${node}.macs.lan;
                  ip = addressing.${cluster}.${node}.ips.lanHost;
                  kind = "rke2";
                  parent = cluster;
                  role = node;
                  ownership = "personal";
                };
              }) (builtins.attrNames addressing.${cluster})
            ) (builtins.attrNames addressing);
          in
          builtins.listToAttrs rke2HostList
        );
      };

      # Network SEGMENTS for flow attribution — the single source nnh (the netflow
      # collector) derives its NetName + AS labelling from, replacing its hardcoded
      # `selfBase`/`gatewayNetworks`.  ndh owns the HOME spans (asn 65000); the
      # cluster spans (65010/65020) are projected from rke2lab's blueprint
      # (`networkBlueprint.segments`) and unioned in.  Akvorado merges
      # most-specific-prefix-wins, so the broad home fallbacks coexist with the finer
      # cluster /27s.  The Bouygues delegated IPv6 /64 is deliberately ABSENT — it is
      # ISP-assigned/dynamic, resolved live by nnh, not committed.
      #
      # Uniform shape (shared with rke2lab): every segment is the attribution triple
      # `{cidr, name, asn}` plus, WHEN ndh runs that network's gateway/DNS, the
      # managed-network facts — `gateway`, a DNS `domain`, and the static `hosts`
      # reservations (`{name, ip}`, plus `mac` for a MAC-known dhcp-host).  A pure
      # attribution span carries just the triple.  `dhcp` (a range string, as on
      # rke2lab's cluster nets) is omitted here: bare-br runs auto-range DHCP with no
      # range pinned in the catalog — same rule as omitting `domain` when there is no
      # DNS zone.  The per-baremetal `-net /25` carries the rich facts; the `-link
      # /30` and the /12 supernet stay attribution-only.
      segments =
        let
          # cidr is the attribution key (prefix→{name,asn}); two entries for the
          # same cidr collide in that map. Collapse same-cidr segments: preserve
          # first-seen order, union their `hosts`, and keep the FIRST-defined scalar
          # facts so a rich ndh segment (domain/gateway) is not clobbered by a
          # host-only contribution (e.g. nnh's inlet/outlet, which mirror ndh's
          # nikopol-baremetal-net cidr on purpose). Catalog is lib-free → builtins.
          mergeSegmentsByCidr =
            segs:
            let
              cidrsInOrder = builtins.foldl' (
                acc: s: if builtins.elem s.cidr acc then acc else acc ++ [ s.cidr ]
              ) [ ] segs;
              mergeGroup =
                c:
                let
                  group = builtins.filter (s: s.cidr == c) segs;
                  # Scalars must AGREE across contributors — union where a key is
                  # defined once, throw LOUD on a genuine clash (no silent drop).
                  checkMerge =
                    a: b:
                    let
                      clashes = builtins.filter (k: (a ? ${k}) && a.${k} != b.${k}) (builtins.attrNames b);
                    in
                    if clashes != [ ] then
                      throw "netplan segment ${c}: contributors disagree on ${builtins.concatStringsSep ", " clashes}"
                    else
                      a // b;
                  scalars = builtins.foldl' checkMerge { } (map (s: builtins.removeAttrs s [ "hosts" ]) group);
                in
                if builtins.any (s: s ? hosts) group then
                  scalars // { hosts = builtins.concatMap (s: s.hosts or [ ]) group; }
                else
                  scalars;
            in
            map mergeGroup cidrsInOrder;
        in
        mergeSegmentsByCidr (
          [
            {
              cidr = "192.168.1.0/24";
              name = "home";
              asn = 65000;
            }
            {
              cidr = "192.168.1.0/27";
              name = "home-dynamic";
              asn = 65000;
            }
            {
              cidr = "100.64.0.0/10";
              name = "tailnet";
              asn = 65000;
            }
            {
              cidr = "10.0.0.0/8";
              name = "home";
              asn = 65000;
            }
            # 172.16.0.0/12 is reserved for per-BAREMETAL instance segments.  Each baremetal
            # host (nikopol today; bioskop later) owns a slice with an Incus segment + dnsmasq
            # DNS domain + a subnet route advertised into the tailnet, so peers resolve
            # <inst>.<domain> and reach it — including the off-tailnet corp Mac vz.nikopol,
            # reached over a static /30 via its Incus host (nikopol-nixos).  The per-host
            # sub-prefixes (net /25 + link /30) are DERIVED from `baremetal` (below the `++`),
            # single-sourced.  nnh attributes flows most-specific-prefix-wins.
            {
              cidr = "172.16.0.0/12";
              name = "baremetal";
              asn = 65000;
            }
            {
              cidr = "192.168.0.0/16";
              name = "home";
              asn = 65000;
            }
            {
              cidr = "169.254.0.0/16";
              name = "home";
              asn = 65000;
            }
            {
              cidr = "fc00::/7";
              name = "home";
              asn = 65000;
            }
            {
              cidr = "fe80::/10";
              name = "home";
              asn = 65000;
            }
          ]
          ++ (builtins.concatMap (
            bm:
            [
              # The managed /25 (Incus bare-br + dnsmasq): gateway, the `.<domain>` DNS
              # zone, and a static host-record for the off-DHCP vz-host (a corp Mac at a
              # /30 address, or an on-tailnet bare-metal at its LAN address — no `mac`,
              # it is not a dnsmasq DHCP client).  DHCP clients (the nnh collector, other
              # instances) auto-register in the zone and are NOT catalog hosts.
              {
                cidr = bm.netCidr;
                name = "${bm.domain}-baremetal-net";
                asn = 65000;
                gateway = bm.netGateway;
                domain = bm.domain;
                hosts = [
                  {
                    name = "vz.${bm.domain}";
                    ip = bm.vzHostAddress;
                  }
                ];
              }
            ]
            # The static /30 link exists only for a vz-host that can't join the tailnet
            # (the corporate Mac); on-tailnet bare-metals declare no `linkCidr`.  It is an
            # attribution-only span (the P2P transport; the dnsmasq that registers the
            # vz-host lives on the /25 above).  (Catalog is lib-free — plain `if`, not
            # `lib.optionals`.)
            ++ (
              if bm ? linkCidr then
                [
                  {
                    cidr = bm.linkCidr;
                    name = "${bm.domain}-baremetal-link";
                    asn = 65000;
                  }
                ]
              else
                [ ]
            )
          ) (builtins.attrValues baremetal))
          ++ (networkBlueprint.segments or [ ])
        );

      # asn → canonical AS name (the `asns` dictionary nnh names its ASes with).
      # Cluster ASNs (65010/65020) come from the blueprint; home (65000) is ndh's.
      asns = (networkBlueprint.asns or { }) // {
        "65000" = "home";
      };

      # Per-baremetal instance segments (defined in the `let` above) — the single source
      # the Darwin corp-Mac package and the NixOS Incus host derive addresses from.
      baremetal = baremetal;

      tailnet = {
        cidr = "100.64.0.0/10";
        domain = ".mammoth-skate.ts.net";

        # Tailnet members and the structured-name service prefixes each
        # exposes.  Consumed by modules/{darwin,nixos}/headscale-daemon.nix
        # to render headscale `dns.extra_records` as CNAME entries:
        # `<service>.<host>.mammoth-skate.ts.net` → `<host>.mammoth-skate.ts.net`.
        #
        # MagicDNS already provides the bare-host A record
        # (`<host>.mammoth-skate.ts.net` → tailnet IP), so the CNAME
        # chain ends at MagicDNS — no hardcoded IPs in the catalog.
        # Tailscaled (patched, see overlays/tailscale.nix) chases the
        # CNAME locally and emits one CNAME RR ahead of the resolved A
        # in the answer.
        #
        # `vz.<host>` is intentionally absent from this DNS section.
        # The SSH alias by the same name still exists for nikopol (only),
        # but it doesn't go through tailnet DNS — the bare metal hosting
        # nikopol can't be a tailnet member (corp-managed Mac, VPN binaries
        # not allowed there), so a tailnet record targeting it would have
        # nothing to resolve to.  Instead, `vz.nikopol` resolves via the
        # per-baremetal split-DNS zone (the segment's dnsmasq host-record)
        # and is reached over the advertised subnet route — see the single
        # `vz.nikopol` stanza in modules/home-manager/ssh-tailnet-hosts.nix.
        #
        # Bioskop has no equivalent: it IS its own bare metal.  No
        # `vz.bioskop` alias exists.
        hosts = {
          bioskop = {
            serviceNames = [
              "rdp"
              "ssh-host"
              # Phase A bootstrap: the headscale primary lives on
              # bioskop, so `headscale.bioskop.<zone>` resolves to the
              # bare-metal Mac itself.  Phase B (cluster) will move this
              # alias onto the RKE2 ingress.
              "headscale"
            ];
          };
          nikopol = {
            serviceNames = [
              "rdp"
              "ssh-host"
            ];
          };
        };
      };
      # Internet-facing anchor: Bouygues Telecom (Bbox) residential
      # connection, dynamic public IPv4 tracked by Duck DNS at
      # mammoth-skate.duckdns.org.  Port-forwards from the WAN router
      # map specific ports onto bioskop inside the LAN:
      #
      #   WAN tcp/2222   →  bioskop  tcp/22     (SSH)
      #   WAN tcp/41841  →  bioskop  tcp/41841  (Headscale control + DERP)
      #   WAN udp/3478   →  bioskop  udp/3478   (Headscale STUN)
      #
      # Additional ports can be added here as they are configured on the
      # router.  Consumers that need a stable internet URL (e.g.
      # off-LAN SSH, tailscale DERP relay, remote headscale join) read
      # from this block instead of hard-coding strings.
      wan = {
        ddnsHostname = "mammoth-skate.duckdns.org";
        router = "mammoth-skate";
        isp = "bouygues";
        # Port-forward map: externalPort → { hostName, internalPort, protocol }.
        # Only ports actually configured on the Bbox live here; adding
        # a new one requires both a router config change and an entry
        # here.
        portForwards = {
          "2222" = {
            hostName = "bioskop";
            internalPort = 22;
            protocol = "tcp";
            description = "SSH into bioskop from off-LAN";
          };
          "41841" = {
            hostName = "bioskop";
            internalPort = 41841;
            protocol = "tcp";
            description = "Headscale control plane (registration, coordination)";
          };
          # Port 3478 (STUN) removed: headscale now uses Tailscale's public
          # DERP map which includes public STUN servers (stun.l.google.com,
          # etc.) for NAT traversal. DERP relays also from Tailscale
          # infrastructure when direct WireGuard connections fail.
          # Self-hosted DERP/STUN disabled to avoid off-LAN reachability
          # complexity.
        };
      };
    };
}
