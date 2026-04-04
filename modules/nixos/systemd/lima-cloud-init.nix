{
  config,
  modulesPath,
  pkgs,
  lib,
  ...
}:

let
  LIMA_CIDATA_MNT = "/mnt/lima-cidata";
  LIMA_CIDATA_DEV = "/dev/disk/by-label/cidata";
  limaCloudInit = pkgs.writeShellApplication {
    name = "lima-cloud-init";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      util-linux
      shadow
      yq-go
      gnused
      gnugrep
      systemd
      findutils
      gawk
      iproute2
    ];
    text = builtins.readFile ./lima-cloud-init.sh;
  };
in
{
  imports = [ ];

  systemd.services.lima-cloud-init = {
    description = "Reconfigure the system from lima-cloud-init userdata on startup";

    after = [
      "network-pre.target"
      "zpool-init.service"
    ];
    wants = [ "zpool-init.service" ];
    before = [
      "multi-user.target"
      "replay-virtiofs-udev.service"
    ];
    wantedBy = [ "multi-user.target" ];

    restartIfChanged = true;

    # Use wrapped binary to ensure stable dependency closure instead of path attr.
    serviceConfig.ExecStart = "${limaCloudInit}/bin/lima-cloud-init";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      ExecStartPre = [ "${pkgs.coreutils}/bin/mkdir -p /var/log" ];
    };

    unitConfig = {
      X-StopOnRemoval = false;
    };

    # Create a wrapper script that logs to files as well
    environment = {
      LIMA_CLOUD_INIT_LOG = "/var/log/lima-cloud-init.log";
      LIMA_CLOUD_INIT_OUTPUT_LOG = "/var/log/lima-cloud-init-output.log";
    };
  };

  systemd.services.replay-virtiofs-udev = {
    description = "Replay virtiofs udev events after boot";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/udevadm trigger -s virtio -c bind";
    };
  };

  fileSystems = {
    "${LIMA_CIDATA_MNT}" = {
      device = "${LIMA_CIDATA_DEV}";
      fsType = "auto";
      options = [
        "ro"
        "mode=0700"
        "dmode=0700"
        "overriderockperm"
        "exec"
        "uid=0"
      ];
    };
  };

  environment.etc = {
    environment.source = "${LIMA_CIDATA_MNT}/etc_environment";
  };

  # Enable NAT for Incus containers to reach internet via host
  networking.nat = {
    enable = true;
    # Internal interfaces carrying container traffic
    # - vmlan0/vmlan1: Lima bridged interfaces (vmlan1 for Incus lan-br bridge)
    # - podman0: Podman bridge interface
    internalInterfaces = [
      "vmlan0"
      "vmlan1"
      "podman0"
    ];
    # External interface with default route (primary Lima network interface)
    externalInterface = "enp0s1"; # Adjust if your primary outbound interface differs
  };

  environment.systemPackages = with pkgs; [
    bash
    sshfs
    fuse3
    git
    openssh
  ];

  boot.kernel.sysctl = {
    "kernel.unprivileged_userns_clone" = 1;
    "net.ipv4.ping_group_range" = "0 2147483647";
    "net.ipv4.ip_unprivileged_port_start" = 0;
    # Disable bridge netfilter to allow direct L2 communication between Incus containers
    # Without this, bridge traffic goes through iptables which blocks cross-container traffic
    # Use mkForce to override the default settings in modules/nixos/default.nix
    "net.bridge.bridge-nf-call-iptables" = lib.mkForce 0;
    "net.bridge.bridge-nf-call-ip6tables" = lib.mkForce 0;
    "net.bridge.bridge-nf-call-arptables" = lib.mkForce 0;
  };
}
