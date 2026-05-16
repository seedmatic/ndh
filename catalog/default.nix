{ cacheTrust }:
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

      # LAN-internal DNS zone served closed-world by bioskop's dnsmasq.
      # Names rendered from `hosts` below follow the structured shape
      #
      #     <service>.<host>.<zone>
      #
      # mirroring the SSH alias convention from
      # modules/home-manager/ssh-tailnet-hosts.nix.  See
      # modules/.common.d/dns-zone-mammoth-skate.nix for the renderer.
      zone = "mammoth-skate.test";

      # Static DHCP reservations on `mammoth-skate`.  Source of truth
      # for the catalog; reconciled against the bbox via the
      # `bbox-reconcile` script which reads /api/v1/dhcp/clients and
      # diffs against this map.
      #
      # Schema:
      #   mac    — primary key for bbox reconciliation
      #   ip     — static reservation IP
      #   kind   — role for downstream consumers; values:
      #              darwin-host  → top-level RDP-able Mac
      #              nixos        → NixOS guest VM
      #              vz-host      → bare-metal VZ bridge interface
      #              rke2         → RKE2 cluster member (requires `role`)
      #              wifi-iface   → wifi NIC (skipped by DNS zone)
      #   parent — top-level host this entry belongs under (omitted for
      #            top-level hosts themselves).
      #   role   — local label within `kind` (only used by `kind=rke2`
      #            today: master / peer{1,2,3} / worker{1,2}).
      #
      # FQDN composition (see dns-zone-mammoth-skate.nix):
      #
      #   top-level host (no parent):
      #       rdp-host.<key>.<zone>     A      <ip>
      #
      #   nested host (parent set):
      #     <kind not rke2>:
      #       <kind>.<parent>.<zone>     A      <ip>
      #     <kind = rke2>:
      #       <role>.rke2.<parent>.<zone>  A   <ip>
      #
      #   wifi-iface entries are skipped.
      #
      # Top-level hosts also get a CNAME from <key>.<zone> to the
      # canonical rdp-host record so muscle-memory `dig bioskop.<zone>`
      # resolves.
      hosts = {
        # bioskop: bare-metal Mac (the daily driver), top-level.
        bioskop = {
          mac = "00:30:93:1d:0e:48";
          ip = "192.168.1.129";
          kind = "darwin-host";
        };
        bioskop-wifi = {
          mac = "ca:f1:1a:ef:69:9f";
          ip = "192.168.1.158";
          kind = "wifi-iface";
          parent = "bioskop";
        };
        bioskop-nixos = {
          mac = "10:66:6a:4c:27:01";
          ip = "192.168.1.130";
          kind = "nixos";
          parent = "bioskop";
        };

        # nikopol: a Tart/VZ macOS guest (the catalog Mac), top-level.
        # The underlying bare metal is a near-stock host whose only job
        # is hosting this VM; only its VZ-bridge interface appears on
        # the LAN as `nikopol-vz` below.
        nikopol = {
          mac = "86:b7:a1:96:1a:9f";
          ip = "192.168.1.33";
          kind = "darwin-host";
        };
        nikopol-vz = {
          # Bare-metal VZ bridge — connectivity only, IP not
          # load-bearing.  Used by the `vz-host.<host>` ssh alias to
          # reach the bare-metal screen-sharing path.
          mac = "84:2f:57:d4:36:be";
          ip = "192.168.1.65";
          kind = "vz-host";
          parent = "nikopol";
        };
        nikopol-nixos = {
          mac = "10:66:6a:4c:d6:01";
          ip = "192.168.1.34";
          kind = "nixos";
          parent = "nikopol";
        };

        # RKE2 control planes.  Tart-derived MACs follow the
        # `10:66:6a:4c:${hostByteHex}:NN` scheme (see
        # modules/darwin/tart-config.nix).
        bioskop-peer3-control-node = {
          mac = "10:66:6a:4c:00:03";
          ip = "192.168.1.134";
          kind = "rke2";
          parent = "bioskop";
          role = "peer3";
        };
        bioskop-worker1-control-node = {
          mac = "10:66:6a:4c:00:0a";
          ip = "192.168.1.135";
          kind = "rke2";
          parent = "bioskop";
          role = "worker1";
        };
        bioskop-worker2-control-node = {
          mac = "10:66:6a:4c:00:0b";
          ip = "192.168.1.136";
          kind = "rke2";
          parent = "bioskop";
          role = "worker2";
        };
        nikopol-master-control-node = {
          mac = "10:66:6a:4c:01:00";
          ip = "192.168.1.35";
          kind = "rke2";
          parent = "nikopol";
          role = "master";
        };
        nikopol-peer1-control-node = {
          mac = "10:66:6a:4c:01:01";
          ip = "192.168.1.36";
          kind = "rke2";
          parent = "nikopol";
          role = "peer1";
        };
        nikopol-peer2-control-node = {
          mac = "10:66:6a:4c:01:02";
          ip = "192.168.1.37";
          kind = "rke2";
          parent = "nikopol";
          role = "peer2";
        };
        nikopol-peer3-control-node = {
          mac = "10:66:6a:4c:01:03";
          ip = "192.168.1.38";
          kind = "rke2";
          parent = "nikopol";
          role = "peer3";
        };
      };
    };
    tailnet = {
      cidr = "100.64.0.0/10";
      domain = ".mammoth-skate.ts.net";
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
          description = "Headscale control plane + embedded DERP relay";
        };
        "3478" = {
          hostName = "bioskop";
          internalPort = 3478;
          protocol = "udp";
          description = "Headscale STUN endpoint for WireGuard NAT traversal";
        };
      };
    };
    # Canonical cluster underlay contract from rke2lab netplan (@codebase)
    # Source of truth: rke2lab/netplan (ClusterNetworkBlueprint semantics)
    rke2lab = {
      supernetCidr = "10.80.0.0/18";
      clusterPrefixLength = 21;
      vmnetNetworkName = "vmnet-br";
      clusters = {
        bioskop = {
          index = 0;
          cidr = "10.80.0.0/21";
          gateway = "10.80.0.1";
        };
        nikopol = {
          index = 2;
          cidr = "10.80.16.0/21";
          gateway = "10.80.16.1";
        };
      };
    };
  };
}
