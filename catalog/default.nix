{ cacheTrust }:
{
  caches = cacheTrust.caches;

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
