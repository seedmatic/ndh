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
    };
    tailnet = {
      cidr = "100.64.0.0/10";
      domain = ".mammoth-skate.ts.net";
    };
    # Internet-facing anchor: Bouygues Telecom (Bbox) residential
    # connection, dynamic public IPv4 tracked by Duck DNS at
    # bboxmatic.duckdns.org.  Port-forwards from the WAN router map
    # specific ports onto bioskop inside the LAN:
    #
    #   WAN tcp/2222  →  bioskop  tcp/22    (SSH)
    #
    # Additional ports can be added here as they are configured on the
    # router.  Consumers that need a stable internet URL (e.g.
    # off-LAN SSH, future tailscale DERP relay, remote headscale
    # join) read from this block instead of hard-coding strings.
    wan = {
      ddnsHostname = "bboxmatic.duckdns.org";
      router = "bbox";
      isp = "bouygues";
      # Port-forward map: externalPort → { hostName, internalPort }.
      # Only ports actually configured on the Bbox live here; adding
      # a new one requires both a router config change and an entry
      # here.
      portForwards = {
        "2222" = {
          hostName = "bioskop";
          internalPort = 22;
          description = "SSH into bioskop from off-LAN";
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
