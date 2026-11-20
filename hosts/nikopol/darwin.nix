{ hardware }:
{
  lib,
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

  };
}
