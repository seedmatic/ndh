{ hardware }:
{
  lib,
  config,
  ...
}:
{
  config = {
    # Fabric link for darwin.nikopol itself: alias the VM's en0 with its OWN fabric
    # address (172.16.25.2), distinct from vzhost.nikopol (172.16.24.2), and route
    # the fabric segment + tailnet through the NixOS host's .1 end (172.16.25.1).
    # Mirrors the baremetal-link mechanism, VM side. Run at activation; the VM's
    # bridged link is stable so a LaunchDaemon is not strictly required.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      echo "[fabric-link-vm] applying 172.16.25.2/30 on en0" >&2
      /sbin/ifconfig en0 inet 172.16.25.2 netmask 255.255.255.252 alias 2>/dev/null || true
      /sbin/route -n delete -net 172.16.16.0 -netmask 255.255.248.0 2>/dev/null || true
      /sbin/route -n add -net 172.16.16.0 -netmask 255.255.248.0 172.16.25.1 2>/dev/null || true
      /sbin/route -n delete -net 100.64.0.0 -netmask 255.192.0.0 2>/dev/null || true
      /sbin/route -n add -net 100.64.0.0 -netmask 255.192.0.0 172.16.25.1 2>/dev/null || true
    '';

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

    tart.configGenerator = {
      forceEnable = false;
      # 16 of 48 GiB: the seat keeps 32, so the bare metal is no longer overcommitted; with the
      # guest ARC capped (zfs.nix) 13.2 GiB were measured with the clusters up.
      vmMemoryMiB = 16384;
      # When the operator deploys nikopol's run manifest to a vz host
      # via `nerd-tart-nikopol-deploy`, the wrapper there reads these
      # defaults.  Mirror bioskop's headless+screen-bridge combo so the
      # boot flow is identical regardless of which Mac runs the VM.
      # `Wi-Fi` is the canonical hardware-port name on macOS; reliable
      # on laptops where a Thunderbolt adapter may not be plugged in.
      vmRunBridgeInterface = hardware.vmBridgeService;
      vmRunSerialBridgeEnable = true;
      vmRunSerialBridgeAutoScreen = true;
    };

    # Vector observability aggregator for NixOS disk image builds

    # A vz macOS VM can't run a nested linux-builder, so nikopol always offloads
    # aarch64-linux to its NixOS sibling next door (nikopol-nixos, which also
    # hosts incus). No bootstrap phase applies here — it is remote from day one.
    # The buildMachine (<host>-nixos) is wired by modules/darwin/host-builder.nix;
    # see docs/host-builder-phases.adoc.
    ndh.hostBuilder = "steady";

    # Local LLM gateway (llama-swap only): Qwen on :8000.
    # LiteLLM (the proxy/router) runs on the NixOS peer.
    services.llmGateway = {
      enable = true;
      sopsEncryptedFile = ../../.secrets;
    };

  };
}
