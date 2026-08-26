{ halfRamMiB }:
{
  config,
  ...
}:
{
  config = {
    # Headscale bootstrap daemon RETIRED.  The whole fleet now registers
    # against Tailscale SaaS (ndh.headscaleClient.controller = "saas"
    # everywhere — nikopol, bioskop, and both NixOS VMs), so bioskop no
    # longer runs the home-Mac bootstrap control-plane (it was a single
    # point of failure behind residential DDNS, and served no client once
    # bioskop-nixos migrated to SaaS).  The production headscale target is
    # rke2-hosted, not this bootstrap (see modules/darwin/headscale-daemon.nix
    # header).  To re-arm: role = "primary" + tailnet.headscale.api.enable
    # = true here (+ point the WAN forward at this host).
    services.headscaleBootstrap.role = "none";
    tailnet.headscale.api.enable = false;

    # Materialise the long-lived Tailscale OAuth client on this operator host.
    # ndh is the single source of trust for the tailnet OAuth client; rke2lab
    # holds NO tailscale creds — its seed-master reads this file at `pulumi up`
    # (host-side, from /run/secrets/nix-darwin-home/tailnet.tailscale.client) to
    # source the mesh k8s-operator's client_id/secret. bioskop is the primary
    # operator host that runs the cluster grow; nikopol enables it too (roaming
    # grow). This is the deliberate exception to "client never materialised on a
    # node" (see modules/.common.d/tailnet.nix) — the operator host is not a
    # fleet node, and it already holds the client for scripts/rotate-tailnet-secrets.
    tailnet.tailscale.client.enable = true;
    # sops lands the client under /run/secrets (root-traversed tmpfs, unreachable
    # by the user process / automounted seed container). Mirror it to a persistent
    # user-owned file rke2lab's seed-master reads at `pulumi up`.
    ndh.userSecretMirror."tailnet.tailscale.client" = {
      source = config.sops.secrets."tailnet.tailscale.client".path;
      target = "${config.profile.user.home}/.local/share/ndh/tailnet.tailscale.client";
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

    # macOS 26.5's directory-services consistency pass rewrote the nix-store
    # record's NFSHomeDirectory to /private/var/empty_1 and then LOCKED the
    # record against writes even by root (dscl -change/-create/-delete and
    # sysadminctl -deleteUser all fail with eDSPermissionError). The rewrite
    # can't be undone, so declare the home the record is stuck on: nix-darwin's
    # home-directory check then matches reality and the heal skips (no dscl
    # write). Drop this back to the /var/empty default once the record can be
    # healed (e.g. after a reboot clears the opendirectoryd lock).
    nixStoreIdentity.inboundUserHome = "/private/var/empty_1";

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

    # bioskop-nixos is up and hosts incus — retire the local (bootstrap) QEMU
    # linux-builder and offload aarch64-linux to that sibling. The buildMachine
    # (bioskop-nixos) is wired by modules/darwin/host-builder.nix;
    # see docs/host-builder-phases.adoc.
    ndh.hostBuilder = "steady";
  };
}
