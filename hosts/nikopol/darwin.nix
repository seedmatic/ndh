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

    # Materialise the long-lived Tailscale OAuth client on this operator host so
    # rke2lab's seed-master can source the mesh k8s-operator OAuth at `pulumi up`
    # (single source of trust in ndh; rke2lab holds no tailscale creds). nikopol
    # runs the cluster grow when roaming — see hosts/bioskop/darwin.nix for the
    # rationale and the "client never materialised on a node" exception.
    tailnet.tailscale.client.enable = true;
    # Mirror the /run/secrets client to a persistent user-owned file (see
    # hosts/bioskop/darwin.nix); rke2lab's seed-master reads it at `pulumi up`.
    ndh.userSecretMirror."tailnet.tailscale.client" = {
      source = config.sops.secrets."tailnet.tailscale.client".path;
      target = "${config.profile.user.home}/.local/share/ndh/tailnet.tailscale.client";
    };

    # Keep Darwin user home aligned with vm-mounted persistent volume.
    profile.user.home = lib.mkForce (builtins.toPath "/Volumes/user-home");

    services.nxmaticCachixWatchStore = {
      enable = true;
      sopsEncryptedTokenFile = ../../.secrets;
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

    # A vz macOS VM can't run a nested linux-builder, so nikopol always offloads
    # aarch64-linux to its NixOS sibling next door (nikopol-nixos, which also
    # hosts incus). No bootstrap phase applies here — it is remote from day one.
    # The buildMachine (<host>-nixos) is wired by modules/darwin/host-builder.nix;
    # see docs/host-builder-phases.adoc.
    ndh.hostBuilder = "steady";
  };
}
