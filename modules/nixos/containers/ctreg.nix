{ config, lib, containerRegistrySystem, ... }:

let
  containerName = "ctreg";
  pkgs = containerRegistrySystem.pkgs;
in {
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
        externalInterface = "enp0s1";
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
      allowedDevices = [{
        node = "/dev/net/tun";
        modifier = "rwm";
      }];
      config = { config, pkgs, ... }: {
        imports = [
          ./../container-host.nix
          ./../caddy.nix
          ./../docker-registry.nix
          ./../tailscale.nix
          ./../../common/networking-mammoth-skate.nix
          ({ config, ... }: {
            containerHost = {
              enable = true;
              hostName = containerRegistrySystem.config.limaHost.hostName;
              guestName = containerName;
            };
            tailscale.tags = [ "nixos" "container" ];
            networking = {
              mammoth-skate.enable = true;
              networkmanager = { unmanaged = [ "tailscale+" ]; };
              firewall = {
                enable = true;
                trustedInterfaces = [ "tailscale0" ];
                allowedUDPPorts = [ config.services.tailscale.port ];
                allowedTCPPorts = [ 22 ];
              };
              defaultGateway = "10.233.0.1";
            };
          })
        ];
      };
    };
  };
}
