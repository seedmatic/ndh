{ config, pkgs, lib, ... }:
let user = config.profile.user.name;

in {
  environment.systemPackages = with pkgs; [ incus incus-compose skopeo ];

  users.users."${user}" = { extraGroups = [ "incus-admin" ]; };

  virtualisation.incus = {
    enable = true;
    ui.enable = true;
    package = pkgs.incus;
    preseed = {
      # Only define internalbr0 here for NATted containers
      networks = [{
        name = "internalbr0";
        type = "bridge";
        description = "Internal/NATted bridge";
        config = {
          "ipv4.address" = "auto";
          "ipv4.nat" = "true";
          "ipv6.address" = "auto";
          "ipv6.nat" = "true";
        };
      }];
      profiles = [
        {
          name = "default";
          description = "Instances on the bridged network";
          devices = {
            eth0 = {
              name = "eth0";
              nictype = "bridged";
              parent = "externalbr0"; # Use the NixOS-managed bridge
              type = "nic";
            };
            root = {
              path = "/";
              pool = "default";
              type = "disk";
            };
          };
        }
        {
          name = "bridged";
          description = "Instances bridged to LAN";
          devices = {
            eth0 = {
              name = "eth0";
              nictype = "bridged";
              parent = "externalbr0"; # Use the NixOS-managed bridge
              type = "nic";
            };
            root = {
              path = "/";
              pool = "default";
              type = "disk";
            };
          };
        }
      ];
      storage_pools = [{
        name = "default";
        driver = "zfs";
        config = { source = "tank/nerd/incus"; };
      }];
    };
  };

  networking = {
    useNetworkd = false;
    networkmanager.enable = true;
    # bridges.externalbr0.interfaces = [ "enp0s1" ];
    # interfaces.externalbr0.useDHCP = true; # Host gets an IP from LAN DHCP
    # interfaces.enp0s1.useDHCP =
    #   lib.mkForce false; # Physical NIC does not get its own IP
    firewall.trustedInterfaces =
      [ "externalbr0" "internalbr0" ]; # Allow DHCP/DNS/etc. on bridge
    # interfaces.externalbr0.macAddress =
    #   "52:55:55:71:36:47"; # match your lima.yaml
    # networkmanager.unmanaged = [
    #   "interface-name:enp0s1"
    #   "interface-name:internalbr0"
    #   "interface-name:externalbr0"
    # ];
  };

  system.activationScripts.incusUserConfig = {
    text = ''
      install -d -m 0700 ~root/.config/incus
      cat > ~root/.config/incus/config.yml <<EOF
      default-remote: local
      remotes:
        docker:
          addr: https://docker.io
          protocol: oci
          public: true
        images:
          addr: https://images.linuxcontainers.org
          protocol: simplestreams
          public: true
        ctreg:
          addr: https://ctreg.mammoth-skate.ts.net
          protocol: oci
          public: true
      aliases: {}
      EOF
      chown ${user}:${user} ~${user}/.config/incus/config.yml
      chmod 600 ~${user}/.config/incus/config.yml
    '';
  };
}
