{ halfRamMiB }:
{
  lib,
  config,
  ...
}:
{
  config = {
    # Headscale bootstrap RETIRED fleet-wide (SaaS is the live controller;
    # see hosts/bioskop/darwin.nix).  Nikopol was the standby; now "none"
    # like the retired primary.  Re-arm by flipping a host back to "primary".
    services.headscaleBootstrap.role = "none";

    # Keep Darwin user home aligned with vm-mounted persistent volume.
    profile.user.home = lib.mkForce (builtins.toPath "/Volumes/user-home");

    services.nxmaticCachixWatchStore = {
      enable = true;
      sopsEncryptedTokenFile = ../../.secrets;
    };

    lima.configGenerator = {
      installMaterializerPackage = false;
    };

    tart.configGenerator = {
      forceEnable = false;
      installMaterializerPackage = false;
      vmMemoryMiB = halfRamMiB;
      # When the operator deploys nikopol's run manifest to a vz host
      # via `nerd-tart-nikopol-deploy`, the wrapper there reads these
      # defaults.  Mirror bioskop's headless+screen-bridge combo so the
      # boot flow is identical regardless of which Mac runs the VM.
      # `Wi-Fi` is the canonical hardware-port name on macOS; reliable
      # on laptops where a Thunderbolt adapter may not be plugged in.
      vmRunBridgeInterface = "Wi-Fi";
      vmRunSerialBridgeEnable = true;
      vmRunSerialBridgeAutoScreen = true;
    };

    # Vector observability aggregator for NixOS disk image builds
    bringupObserve = {
      enable = true;
      # Darwin host acts as the aggregator (no upstream endpoint)
      # NixOS VMs forward to this via upstreamEndpoint in their configs
    };

    # aarch64-linux remote builder: this host's own NixOS VM next door (<host>-nixos, which also
    # hosts incus) — nikopol-nixos when building nikopol, bioskop-nixos when building bioskop. The
    # name is DERIVED from the current host (config.profile.host.hostName), not hardcoded, so the
    # same darwin config offloads to the right sibling regardless of which Mac it is built for.
    # A vz macOS VM can't run a nested linux-builder, so aarch64-linux derivations that miss the
    # binary caches (e.g. the rke2lab node-base systemd unit scripts — unique content, no cache hit,
    # and a Darwin host cannot build linux) are offloaded here. <host>-nixos already authorizes root
    # over ssh (root@<host> → <host>-nixos works with root's own identity, and root is a trusted nix
    # user), so no builder key is deployed — the nix daemon (root) reuses that identity. This
    # regenerates /etc/nix/machines and repoints `builders` at it, replacing the stale hand-written
    # file that `builders =` (empty) was ignoring.
    nix.distributedBuilds = true;
    nix.buildMachines = [
      {
        hostName = "${config.profile.host.hostName}-nixos";
        sshUser = "root";
        systems = [ "aarch64-linux" ];
        maxJobs = 8;
        protocol = "ssh-ng";
        supportedFeatures = [
          "big-parallel"
          "kvm"
          "nixos-test"
        ];
      }
    ];
    # The remote builder pulls dependencies straight from the binary caches rather than having the
    # Mac upload its whole closure over ssh.
    nix.settings.builders-use-substitutes = true;
  };
}
