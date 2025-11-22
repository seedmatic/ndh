{ config, pkgs, lib, ... }:
let
  user = config.profile.user.name;
  hostProfile = config.profile.host;
  effectiveHostName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null
        && hostProfile.hostAlias != "")
    then hostProfile.hostAlias
    else hostProfile.hostName;
  hostByteHex = lib.strings.toLower
    (builtins.substring 0 2 (builtins.hashString "sha256" effectiveHostName));
  lanBridgeMac = "10:66:6a:4c:${hostByteHex}:fe";
  fixIncusSocketPerms = pkgs.writeShellScript "fix-incus-socket-perms.sh" ''
    set -euxo pipefail
    find /run/incus -type f -exec chmod g+rw {} +
    find /run/incus -type d -exec chmod g+rwx {} +
  '';

in {
  environment.systemPackages = with pkgs; [ 
    incus 
    incus-compose 
    skopeo 
    debootstrap
    dpkg
    # Additional tools needed by debootstrap for proper Debian image building
    gnused
    gnugrep
    gnutar
    gawk
    util-linux
  ];

  users.users."${user}" = { extraGroups = [ "incus-admin" ]; };

  virtualisation.incus = {
    enable = true;
    ui.enable = true;
    package = pkgs.incus;
    preseed = {
      networks = [
      ];
      profiles = [
        {
          name = "default";
          description = "Instances on the bridged network";
          devices = {
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
    # NetworkManager should not manage vmlan0 - it's used as Incus lan-br bridge member
    networkmanager.unmanaged = [
      "interface-name:vmlan0"
      "interface-name:lan-br"
    ];
    # bridges.externalbr0.interfaces = [ "enp0s1" ];
    # interfaces.externalbr0.useDHCP = true; # Host gets an IP from LAN DHCP
    # interfaces.enp0s1.useDHCP =
    #   lib.mkForce false; # Physical NIC does not get its own IP
    firewall.trustedInterfaces = [
      "+-br*" # Allow DHCP/DNS/etc. on bridges
    ]; # Allow DHCP/DNS/etc. on bridge
    # interfaces.externalbr0.macAddress =
    #   "52:55:55:71:36:47"; # match your lima.yaml
  };

  # Create the lan-br bridge device
  systemd.network.netdevs."20-lan-br" = {
    netdevConfig = {
      Name = "lan-br";
      Kind = "bridge";
      MACAddress = lanBridgeMac;
    };
  };

  # Configure vmlan0 as bridge member
  systemd.network.networks."30-vmlan0" = {
    matchConfig.Name = "vmlan0";
    networkConfig = {
      Bridge = "lan-br";
      # Don't configure IP on the member interface
      DHCP = "no";
      IPv6AcceptRA = "no";
      LinkLocalAddressing = "no";
    };
  };

  # Configure the bridge itself with DHCP
  systemd.network.networks."40-lan-br" = {
    matchConfig.Name = "lan-br";
    linkConfig = {
      MACAddress = lanBridgeMac;
    };
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = "yes";
      LinkLocalAddressing = "no";
    };
  };

  # Ensure lan-br picks up deterministic MAC via udev instead of polling loops (@codebase)
  systemd.network.links."10-lan-br" = {
    matchConfig.OriginalName = "lan-br";
    linkConfig = {
      MACAddress = lanBridgeMac;
      MACAddressPolicy = "none";
    };
  };

  systemd.tmpfiles.rules = [ "d /run/incus 0775 root incus-admin -" ];

  system.activationScripts.incusUserConfig =
    let user = config.profile.user.name;
    in {
      text = ''
        #!/usr/bin/env -S bash -euxo pipefail

        : "Create the incus user config directory and config file"
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

}
