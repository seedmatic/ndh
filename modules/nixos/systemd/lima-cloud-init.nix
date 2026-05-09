{
  config,
  modulesPath,
  pkgs,
  lib,
  ndh,
  ndhSystemd,
  self,
  ...
}:

let
  ndhContext = ndh.context;
  catalog = ndhContext.catalog;
  LIMA_CIDATA_MNT = "/mnt/lima-cidata";
  LIMA_CIDATA_DEV = "/dev/disk/by-label/cidata";
  isLimaProvider = config.ndh.vm.provider == "lima";
  contributedTargetName = ndhSystemd.contributedTargetName;
  zpoolInitServiceName = ndhSystemd.mkServiceName "zpool-init";
  catalogUserName =
    if catalog ? user && catalog.user ? name then
      catalog.user.name
    else
      config.profile.user.name;
  trustedCaPublicKey = lib.removeSuffix "\n" (
    builtins.readFile (
      pkgs.runCommand "trusted-user-ca-public-key" { buildInputs = [ pkgs.yq-go ]; } ''
        yq -r '."mammoth-skate".public // ""' "${self}/modules/home-manager/ssh.d/keys.yaml" > "$out"
      ''
    )
  );
  linuxBuilderPublicKey = lib.removeSuffix "\n" (
    builtins.readFile (
      pkgs.runCommand "linux-builder-public-key" { buildInputs = [ pkgs.yq-go ]; } ''
        yq -r '."linux-builder".public // ""' "${self}/modules/home-manager/ssh.d/keys.yaml" > "$out"
      ''
    )
  );
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
    text =
      builtins.replaceStrings
        [
          "@profileUserName@"
          "@linuxBuilderPublicKey@"
          "@trustedCaPublicKey@"
        ]
        [
          catalogUserName
          linuxBuilderPublicKey
          trustedCaPublicKey
        ]
        (builtins.readFile ./lima-cloud-init.sh);
  };
in
{
  imports = [ ];

  config = lib.mkIf isLimaProvider {
    systemd.services.${ndhSystemd.mkUnitName "lima-cloud-init"} = {
      description = "Reconfigure the system from lima-cloud-init userdata on startup";

      after = [
        "network-pre.target"
        zpoolInitServiceName
      ];
      wants = [ zpoolInitServiceName ];
      before = [
        "multi-user.target"
        (ndhSystemd.mkServiceName "replay-virtiofs-udev")
      ];
      wantedBy = [ contributedTargetName ];

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
        # No-op gracefully when running under a VM engine that does not provide
        # a cidata disk (e.g. Tart).  systemd treats an unmet Condition as a
        # clean success (exit 0) — dependents that use Wants= still start.
        ConditionPathExists = LIMA_CIDATA_DEV;
      };

      # Create a wrapper script that logs to files as well
      environment = {
        LIMA_CLOUD_INIT_LOG = "/var/log/lima-cloud-init.log";
        LIMA_CLOUD_INIT_OUTPUT_LOG = "/var/log/lima-cloud-init-output.log";
      };
    };

    systemd.services.${ndhSystemd.mkUnitName "replay-virtiofs-udev"} = {
      description = "Replay virtiofs udev events after boot";
      wantedBy = [ contributedTargetName ];
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
          # Don't stall boot when running under Tart (no cidata disk attached).
          "nofail"
          "x-systemd.device-timeout=5"
        ];
      };
    };

    environment.etc = {
      # Empty fallback so /etc/environment is never a broken symlink when the
      # cidata disk is absent (e.g. Tart engine).  Lima's cloud-init service
      # writes Lima-specific env overrides to /etc/environment.d/ at runtime.
      environment.text = lib.mkDefault "";
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
  };
}
