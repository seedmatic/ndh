{
  config,
  lib,
  containerRegistrySystem,
  worktreePath,
  ...
}:

let
  containerName = "ctreg";
  pkgs = containerRegistrySystem.pkgs;
in
{
  options.containerHost.ctreg = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the container registry service.";
    };
    # Add more nested options here as needed
  };

  config = lib.mkIf config.containerHost.ctreg.enable {
    networking = {
      nat = {
        enable = true;
        internalInterfaces = [ "ve-${containerName}" ];
        # Use vmlan0 interface (bridged LAN) for external connectivity
        externalInterface = if config.limaHost.isGuest then "vmlan0" else "enp0s1";
      };
    };
    containers."${containerName}" = {
      privateNetwork = true;
      enableTun = true;
      hostAddress = "10.233.0.1";
      localAddress = "10.233.0.2";
      ephemeral = false;
      autoStart = true;
      bindMounts = {
        "/run/tailscale/auth.key" = {
          hostPath = "/run/tailscale/auth.key";
          isReadOnly = false;
        };
      };
      allowedDevices = [
        {
          node = "/dev/net/tun";
          modifier = "rwm";
        }
      ];
      config =
        { config, pkgs, ... }:
        {
          imports = [
            ./../container-host.nix
            ./../caddy.nix
            ./../docker-registry.nix
            ./../tailscale.nix
            (worktreePath.of "modules/nixos/networking-mammoth-skate.nix")
            (
              { config, ... }:
              {
                containerHost = {
                  enable = true;
                  hostName = containerRegistrySystem.config.limaHost.hostName;
                  guestName = containerName;
                };
                # Role = service (driven by an operator); kind = incus
                # (runs inside the NixOS guest's Incus runtime).
                # Vocabulary defined at catalog/headscale/acl.hujson.
                tailscale.tags = [
                  "service"
                  "incus"
                ];
                networking = {
                  mammoth-skate.enable = true;
                  networkmanager = {
                    unmanaged = [ "tailscale+" ];
                  };
                  firewall = {
                    enable = true;
                    trustedInterfaces = [ "tailscale0" ];
                    allowedUDPPorts = [ config.services.tailscale.port ];
                    allowedTCPPorts = [ 22 ];
                  };
                  defaultGateway = "10.233.0.1";
                };
              }
            )
          ];
        };
    };
  };
}
