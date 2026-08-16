{ cacheTrust, networkBlueprint }:
{
  caches = cacheTrust.caches;

  # Headscale policy + tag vocabulary + per-host server URLs.  See
  # catalog/headscale/default.nix.
  headscale = import ./headscale;

  # v2 has a single OS user; the catalog holds it directly without the
  # former per-profile wrapper.
  user = {
    name = "nxmatic";
    description = "Stephane Lacoin (aka nxmatic)";
    email = "stephane.lacoin@gmail.com";
  };

  netplan = {
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

    # Network SEGMENTS (cidr → name → asn) for flow attribution — the single
    # source nnh (the netflow collector) derives its NetName + AS labelling
    # from, replacing its hardcoded `selfBase`/`gatewayNetworks`.  ndh owns the
    # HOME spans (asn 65000); the cluster spans (65010/65020) are projected from
    # rke2lab's blueprint (`networkBlueprint.segments`) and unioned in.  Akvorado
    # merges most-specific-prefix-wins, so the broad home fallbacks coexist with
    # the finer cluster /27s.  The Bouygues delegated IPv6 /64 is deliberately
    # ABSENT — it is ISP-assigned/dynamic, resolved live by nnh, not committed.
    segments = [
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
      # 172.16.0.0/12 is reserved for ROAMING: a per-host /30 vz-host link that the
      # host's NixOS VM subnet-routes into the tailnet (mammoth-skate), so a roaming
      # operator reaches the corp bare metal WITHOUT it being a tailnet member.
      # nikopol is the only roaming host (its NixOS VM routes 172.16.6.0/30);
      # bioskop is stationary and routes 192.168.1.0/24 instead.
      {
        cidr = "172.16.0.0/12";
        name = "roaming";
        asn = 65000;
      }
      {
        cidr = "172.16.6.0/30";
        name = "nikopol-roaming";
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
    ++ (networkBlueprint.segments or [ ]);

    # asn → canonical AS name (the `asns` dictionary nnh names its ASes with).
    # Cluster ASNs (65010/65020) come from the blueprint; home (65000) is ndh's.
    asns = (networkBlueprint.asns or { }) // {
      "65000" = "home";
    };

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
      # nothing to resolve to.  Instead, the alias resolves at SSH-
      # connection time:
      #   - From the nikopol VM: ARP-cache lookup of the bare metal's
      #     stable hardware MAC, on whatever Wi-Fi the laptop is on.
      #     See hosts/nikopol/modules/darwin/vz-host-resolver.nix.
      #   - From bioskop / any other operator host: ProxyJump=nikopol
      #     to the VM, then the VM's own resolver.  See
      #     modules/home-manager/ssh-tailnet-hosts.nix.
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
