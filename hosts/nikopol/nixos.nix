{
  config,
  lib,
  ndh,
  ...
}:
let
  # vz.nikopol baremetal segment addresses — single source in the catalog.
  bm = ndh.context.catalog.netplan.baremetal.nikopol;
  netPrefix = lib.last (lib.splitString "/" bm.netCidr);
  linkPrefix = lib.last (lib.splitString "/" bm.linkCidr);
in
{
  config = {
    profile.user.home = lib.mkForce "/home/${config.profile.user.name}";

    # Vector observability agent forwards build events to Darwin aggregator
    bringupObserve = {
      enable = true;
      # Forward to Darwin host Vector aggregator via VM network gateway
      # VM NAT makes the macOS host accessible at 192.168.5.2
      upstreamEndpoint = "http://192.168.5.2:9001";
    };

    # sshfs mounts of the Darwin-side git store (replaces the old NFS /net automount).
    # Root executes the mount but authenticates as nxmatic — the operator who owns the
    # trees — via the CA-signed rdp-host key; remote files map back to uid/gid 501:30001.
    # nikopol keeps its git trees on dedicated /Volumes stores.
    services.sshfsMounts = {
      enable = true;
      remoteHost = "nikopol.local";
      remoteUser = "nxmatic";
      identityFile = "/var/lib/ndh/ssh-keys/rdp-host";
      mounts = [
        {
          remotePath = "/Volumes/git-worktree-store";
          localPath = "/net/nikopol.local/Volumes/git-worktree-store";
        }
        {
          remotePath = "/Volumes/git-bare-store";
          localPath = "/net/nikopol.local/Volumes/git-bare-store";
        }
      ];
    };

    # --- vz.nikopol baremetal segment (nikopol-only) ------------------------------
    # This VM is the Incus host + subnet router for the corp Mac (vz.nikopol), which
    # cannot join the tailnet.  Addresses derive from the catalog
    # (netplan.baremetal.nikopol).  The 172.16.6.0/24 aggregate is advertised into the
    # tailnet so peers resolve <inst>.nikopol (split-DNS → this host's dnsmasq) and
    # reach the corp Mac; on the Tailscale SaaS controller (current) the advertise +
    # split-DNS + route approval are runtime console steps, and become declarative once
    # Headscale is the live control-plane.  No NAT — source IPs preserved.  See
    # docs/network-topology-c4.adoc.
    #
    # Managed /25 (Incus dnsmasq) carrying the netflow instances behind this host, with
    # a `.<domain>` DNS zone and a static host-record for the (off-DHCP) corp Mac.
    # Relies on virtualisation.incus.preseed.networks merging across modules (standard
    # NixOS submodule list merge with the shared modules/nixos/incus.nix); if that ever
    # conflicts, create bare-br via `incus network create` instead.
    virtualisation.incus.preseed.networks = [
      {
        name = "bare-br";
        type = "bridge";
        config = {
          "ipv4.address" = "${bm.netGateway}/${netPrefix}";
          "ipv4.nat" = "false";
          "ipv4.dhcp" = "true";
          "ipv6.address" = "none";
          "dns.domain" = bm.domain;
          # Static A record so `vz.${domain}` resolves to the corp Mac (not a dnsmasq
          # DHCP client — its .253 is a hard-set en0 alias).  The collector and other
          # instances register in the `.${domain}` zone via DHCP when nnh attaches them
          # to bare-br — their addresses are nnh's (from its own blueprint), not ours.
          "raw.dnsmasq" = "host-record=vz.${bm.domain},${bm.vzHostAddress}\n";
        };
      }
    ];
    networking.firewall.trustedInterfaces = [ "bare-br" ];
    networking.networkmanager.unmanaged = [ "interface-name:bare-br" ];

    # Static /30 link end toward the corp Mac, as a secondary address on lan-br
    # (systemd-networkd-managed — networkd is force-enabled by
    # bringup-minimal-system.nix).  DHCP on lan-br still provides the .34 LAN lease.
    systemd.network.networks."40-lan-br".address = [ "${bm.hostAddress}/${linkPrefix}" ];

    # Route between the /30 link and the managed /25 so the corp Mac reaches the
    # netflow instances (Incus enables forwarding for managed bridges too; explicit
    # here for the /30 <-> /25 path).
    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;

    # Clamp forwarded TCP MSS to the per-route PMTU.  This host forwards between
    # 1500-MTU segments (bare-br /25, lan-br /30 toward the corp Mac) and the
    # 1280-MTU tailnet (tailscale0): a netflow instance ↔ tailnet peer flow crosses
    # that 1500→1280 step, so without a clamp the larger SYN/data blackholes on
    # PMTUD (DF set, ICMP frag-needed often filtered).  `size set rt mtu` rewrites
    # the SYN MSS to the actual egress-route MTU per flow, so intra-1500 paths stay
    # 1460 (no-op) while tailnet-bound flows drop to 1240.  firewall.enable is off
    # here, so this lands as its own nftables table rather than a firewall rule.
    networking.nftables.tables.mss-clamp = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority mangle; policy accept;
          tcp flags syn tcp option maxseg size set rt mtu
        }
      '';
    };
  };
}
