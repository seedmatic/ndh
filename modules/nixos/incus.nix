{ config, pkgs, lib, ... }:
let
  user = config.profile.user.name;
  fixIncusSocketPerms = pkgs.writeShellScript "fix-incus-socket-perms.sh" ''
    set -euxo pipefail
    find /run/incus -type f -exec chmod g+rw {} +
    find /run/incus -type d -exec chmod g+rwx {} +
  '';

  # Create an FHS environment for distrobuilder/debootstrap to work properly
  distrobuilderFHS = pkgs.buildFHSUserEnv {
    name = "distrobuilder-fhs";
    targetPkgs = pkgs: with pkgs; [
      distrobuilder
      debootstrap
      dpkg
      gnused
      gnugrep
      gnutar
      gzip
      gawk
      util-linux
      coreutils
      findutils
      bash
      perl
      wget
      curl
      cacert
    ];
    runScript = "distrobuilder";
  };

in {
  environment.systemPackages = with pkgs; [ 
    incus 
    incus-compose 
    skopeo 
    distrobuilderFHS  # Use FHS-wrapped version instead of bare distrobuilder
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
    # NetworkManager should not manage vmlan1 - it's dedicated for Incus lan-br bridging
    networkmanager.unmanaged = [
      "interface-name:vmlan1"
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

  security.wrappers.distrobuilder = {
    source = "${distrobuilderFHS}/bin/distrobuilder-fhs";
    owner = "root";
    group = "incus";
    setuid = true;
    permissions = "u+rx,g+rx,o+rx";
  };
}
