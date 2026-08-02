{
  config,
  lib,
  ndh,
  worktreePath,
  ...
}:
{
  imports = [ (worktreePath.of "modules/.common.d/dns-servers.nix") ];

  options.networking.mammoth-skate = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable networking configuration for the mammoth-skate tailnet.";
    };
  };

  config = lib.mkIf config.networking.mammoth-skate.enable (
    let
      ndhContext = ndh.context;
      tailnetDomain =
        if ndhContext.catalog.netplan ? tailnet then ndhContext.catalog.netplan.tailnet.domain else "";
      bareDomain = lib.removePrefix "." tailnetDomain;
    in
    {
      networking = {
        enableIPv6 = true; # Explicitly enable IPv6
        firewall = {
          enable = true;
          allowedTCPPorts = [
            53
            22
            2222
            80
            443 # DNS, SSH, HTTP/HTTPS
          ];
          allowedUDPPorts = [
            53
            67
            68
          ];
          # Note: Kubernetes API (6443, 10250) and NodePort range (30000-32767) are NOT exposed
          # to the public internet. Access is via Tailscale (tailscale0 is a trusted interface).
          logRefusedPackets = true;
        };
        nftables.enable = true;
        networkmanager.enable = true;
        wireless.enable = lib.mkDefault false;
        # Use common DNS servers with IPv6 and IPv4 support
        # Note: Tailscale DNS (100.100.100.100) is added by the Tailscale module
        nameservers = config.common.dnsServers;
        fqdn = config.networking.hostName + tailnetDomain;
        search = lib.optional (bareDomain != "") bareDomain;
      };
      systemd.network.networks.eth0.networkConfig = {
        DHCP = "yes";
        LinkLocalAddressing = "yes";
        IPv6AcceptRA = true; # Accept IPv6 Router Advertisements
      };
    }
  );
}
