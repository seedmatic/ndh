{ hardware }:
{
  config,
  ...
}:
{
  imports = [ ../../modules/darwin/host-darwin-base.nix ];

  config = {
    ndh.hostDarwinBase.enable = true;

    # Developer tools (BrowserOS neo + omo) for this host.
    hm.imports = [
      ../../modules/home-manager/developer-tools.nix
      ./modules/home-manager/omo.nix
    ];

    # Headscale bootstrap daemon RETIRED (role = "none" is set by the common
    # host-darwin-base module).  bioskop additionally disables the headscale
    # API.  The whole fleet now registers against Tailscale SaaS.
    tailnet.headscale.api.enable = false;

    # Bioskop is the authoritative Duck DNS updater for the WAN
    # anchor recorded in catalog.netplan.wan.ddnsHostname.  nikopol
    # (a roaming laptop) does not attempt to track the home IP.
    services.ddnsClient = {
      enable = true;
      sopsEncryptedTokenFile = ../../.secrets;
    };

    # bioskop holds the TLS authority (the operator seat): its activation restores the Incus cluster certificate.
    ndh.incusClusterCert.atActivation = true;

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
      # M4 Pro: 12 cores, 8P+4E. 8 vCPUs took every P-core, and a vCPU the host preempts stops
      # answering IPIs: the guest's soft lockups and RCU stalls of 2026-10. 6 leaves macOS 2 P-cores.
      vmCpuCount = 6;
      # 24 of 64 GiB: with the guest ARC capped (zfs.nix) the clusters fit, and the rest stays
      # with macOS for a local model on the GPU.
      vmMemoryMiB = 24576;
      vmRunBridgeInterface = hardware.vmBridgeService;
      vmRunSerialBridgeEnable = true;
      vmRunSerialBridgeAutoScreen = true;
      vmRunNestedVirt = true;
    };

    # bioskop-nixos is up and hosts incus — retire the local (bootstrap) QEMU
    # linux-builder and offload aarch64-linux to that sibling. The buildMachine
    # (bioskop-nixos) is wired by modules/darwin/host-builder.nix;
    # see docs/host-builder-phases.adoc.

    # The guests are evaluated here and pushed, so the fleet is switched from this seat only.
    ndh.ndhSwitch.enable = true;
    # bioskop holds the keyring (ndh-keyring).
    ndh.keyring.enable = true;
    # keyhole's bare lives here: the git sops filters derive its age identity from keyring@keyhole's ssh key.
    home-manager.users.${config.profile.user.name}.ndh.gitSops.ageSshKeyFile =
      "/Volumes/git-bare-store/nxmatic/keyhole.git/.ssh/id_ed25519";
  };
}
