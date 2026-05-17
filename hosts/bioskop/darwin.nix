{ halfRamMiB }:
{
  config,
  lib,
  ndh,
  ...
}:
let
  ndhContext = ndh.context;
  # Canonical source-of-truth network values from rke2lab netplan catalog (@codebase)
  rke2labNetplan = ndhContext.catalog.netplan.rke2lab;
  clusterNetwork = rke2labNetplan.clusters.bioskop;
in
{
  config = {
    # Bioskop is the current primary owner of the headscale alias.
    # Darwin-scoped so the NixOS VM hosted here does not inherit the
    # role and run a second daemon (see the exactly-one-primary
    # invariant in modules/darwin/headscale-daemon.nix).
    services.headscaleBootstrap.role = "primary";

    # Expose the `hs` admin CLI wrapper — bioskop is the host from
    # which fleet-level headscale management happens (creating users,
    # minting preauth keys, inspecting nodes).  The local daemon's
    # unix socket would work too, but the api-key path keeps the
    # workflow identical to a future day when admin moves to a remote
    # primary.
    tailnet.headscale.api.enable = true;

    # Tailnet DNS: serve headscale.bioskop.mammoth-skate.ts.net CNAME.
    # Phase A (now): points to bioskop.mammoth-skate.ts.net (Darwin LaunchAgent).
    # Phase B (future): cluster dnsmasq will override to point to RKE2 ingress.
    networking.dnsZoneMammothSkateTailnet.extraCnames = {
      headscale = "bioskop.mammoth-skate.ts.net";
    };

    # Bioskop is the authoritative Duck DNS updater for the WAN
    # anchor recorded in catalog.netplan.wan.ddnsHostname.  nikopol
    # (a roaming laptop) does not attempt to track the home IP.
    services.ddnsClient = {
      enable = true;
      sopsEncryptedTokenFile = ../../.secrets;
    };

    # Two-phase SOPS age key provisioning on Darwin:
    # phase 2 (enforce): key must already exist.
    ndh.sopsAgeKeyBootstrap = {
      phase = "enforce";
      darwinSystemWideKey = true;
    };
    sops.age.keyFile = "/etc/sops/age/keys.txt";

    services.nxmaticCachixWatchStore = {
      enable = true;
      sopsEncryptedTokenFile = ../../.secrets;
    };

    networking.vlan = {
      enable = false; # Temporarily disabled: VLAN 2 currently causes local resolution/routing issues.
      id = 2;
      addressPrefix = "192.168.2";
      parentInterface = "en9";
    };

    networking.staticRoutes = {
      enable = true;
      routes = [
        {
          kind = "net";
          destination = clusterNetwork.cidr;
          gateway = "192.168.1.130";
          interface = "en9";
        }
      ];
    };

    # Network bonding configuration (Darwin only)
    # Combines en0 (built-in) and en8 (OWC hub) for ~1.8 Gbps aggregate bandwidth
    networking.bond = {
      enable = false; # Enable when needed
      interfaces = [
        "en0"
        "en9"
      ];
      mode = "static"; # Static LAG without LACP protocol
    };

    lima.configGenerator = {
      installMaterializerPackage = false;
      vmType = "qemu"; # Use QEMU for having a prompt in emergency mode, which is useful for debugging. VZ doesn't support interactive prompt on boot.
      sshLocalPort = 61022; # Fixed port so nix daemon can reach nerd-nixos as a remote builder.
      # vmMemoryMiB = 8192;
      # vmCpuCores = 6;
    };

    tart.configGenerator = {
      forceEnable = false;
      installMaterializerPackage = false;
      vmCpuCount = 8; # 8 of 14 cores (10P+4E) reserved for nerd-nixos; 6 remain for macOS
      vmMemoryMiB = halfRamMiB;
      vmRunBridgeInterface = "Thunderbolt Ethernet Slot 1";
      vmRunSerialBridgeEnable = true;
      vmRunSerialBridgeAutoScreen = true;
      vmRunNestedVirt = true;
    };

    # Vector observability aggregator for NixOS disk image builds
    bringupObserve = {
      enable = true;
      # Darwin host acts as the aggregator (no upstream endpoint)
      # NixOS VMs forward to this via upstreamEndpoint in their configs
    };
  };
}
