{ config, pkgs, lib, ... }:
let
  user = config.profile.user.name;
  fixIncusSocketPerms = pkgs.writeShellScript "fix-incus-socket-perms.sh" ''
    set -euxo pipefail
    find /run/incus -type f -exec chmod g+rw {} +
    find /run/incus -type d -exec chmod g+rwx {} +
  '';

in {
  environment.systemPackages = with pkgs; [ incus incus-compose skopeo ];

  users.users."${user}" = { extraGroups = [ "incus-admin" ]; };

  virtualisation.incus = {
    enable = true;
    ui.enable = true;
    package = pkgs.incus;
    preseed = {
      networks = [
        {
          name = "internal-br";
          type = "bridge";
          description = "Internal/NATted network bridge";
          config = {
            "ipv4.address" = "auto";
            "ipv4.nat" = "true";
            "ipv6.address" = "auto";
            "ipv6.nat" = "true";
          };
        }
        {
          name = "lan-br";
          type = "bridge";
          description = "LAN bridge";
          config = {
            "bridge.external_interfaces" = "enp0s2";
            "ipv4.address" = "none";
            "ipv4.nat" = "false";
            "ipv6.address" = "none";
            "ipv6.nat" = "false";
          };
        }
      ];
      profiles = [
        {
          name = "default";
          description = "Instances on the internal bridged network";
          devices = {
            eth0 = {
              name = "eth0";
              nictype = "bridged";
              parent = "internal-br";
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
          name = "lan";
          description = "Instances bridged to the local area network (LAN)";
          devices = {
            eth0 = {
              name = "eth0";
              nictype = "bridged";
              parent = "lan-br";
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
    firewall.trustedInterfaces = [
      "+-br*" # Allow DHCP/DNS/etc. on bridges
    ]; # Allow DHCP/DNS/etc. on bridge
    # interfaces.externalbr0.macAddress =
    #   "52:55:55:71:36:47"; # match your lima.yaml
    # networkmanager.unmanaged = [
    #   "interface-name:enp0s1"
    #   "interface-name:internalbr0"
    #   "interface-name:externalbr0"
    # ];
  };

  systemd.tmpfiles.rules = [ "d /run/incus 0775 root incus-admin -" ];

  system.activationScripts.incusUserConfig =
    let user = config.profile.user.name;
    in {
      text = ''
        #!/usr/bin/env -S bash -euxo pipefail

        : Create the incus user config directory and config file
        install -d -m 0775 -o ${user} -g ${user} ~${user}/.config/incus
        cat  <<EoF > ~root/.config/incus/config.yml| install -Dm 600 -o ${user} -g ${user} /dev/stdin ~${user}/.config/incus/config.yml
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
        EoF
      '';
    };

  systemd.services.incus = {
    serviceConfig.ExecStartPost = [ "${fixIncusSocketPerms}" ];
  };

  security.wrappers.distrobuilder = {
    source = "${pkgs.distrobuilder}/bin/distrobuilder";
    owner = "root";
    group = "incus";
    setuid = true;
    permissions = "u+rx,g+rx,o+rx";
  };
}
