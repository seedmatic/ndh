{
  config,
  lib,
  hostProfile ? { },
  ...
}:

let
  kernelModules = [
    "ext4"
    "overlay"
    "vhost_vsock"
    "vsock"
    "br_netfilter"
    "iptable_filter"
    "iptable_nat"
    "ip6table_filter"
    "ip6table_nat"
    "nf_conntrack"
    "nf_conntrack_netlink"
    "nf_tables"
    "nfnetlink"
    "xt_conntrack"
  ];
  supportedFilesystems = {
    ext4 = true;
    overlay = true;
  };
  hostImageMode =
    if hostProfile ? nixosImageMode && hostProfile.nixosImageMode != null then
      hostProfile.nixosImageMode
    else
      "full";
  bootstrapMode = hostImageMode == "bootstrap";
  bootstrapDebug =
    bootstrapMode
    && (if hostProfile ? bootstrapDebug && hostProfile.bootstrapDebug != null then hostProfile.bootstrapDebug else false);
  consoleCfg = config.consoleLogging;
  grubDebugKernelParams = lib.concatStringsSep " " (
    [
      "init=/nix/var/nix/profiles/system/init"
      "console=hvc0"
      "console=ttyAMA0"
      "console=ttyS0"
      "console=tty1"
      "systemd.show_status=1"
      "rd.systemd.show_status=1"
      "logo.nologo"
      "rootwait"
      "rootdelay=5"
      "loglevel=7"
      "ignore_loglevel"
      "rd.udev.log_level=debug"
      "boot.trace"
    ]
  );
  grubExerciseEntries = lib.optionalString bootstrapDebug ''
    submenu "NixOS boot exercises (@codebase)" {
      menuentry "Exercise: root=LABEL=nixos" {
        search --set=rootfs --label nixos
        linux ($rootfs)/nix/var/nix/profiles/system/kernel ${grubDebugKernelParams} root=LABEL=nixos
        initrd ($rootfs)/nix/var/nix/profiles/system/initrd
      }

      menuentry "Exercise: root=/dev/vda2" {
        search --set=rootfs --label nixos
        linux ($rootfs)/nix/var/nix/profiles/system/kernel ${grubDebugKernelParams} root=/dev/vda2
        initrd ($rootfs)/nix/var/nix/profiles/system/initrd
      }

      menuentry "Exercise: initrd break (rd.break=mount)" {
        search --set=rootfs --label nixos
        linux ($rootfs)/nix/var/nix/profiles/system/kernel ${grubDebugKernelParams} root=LABEL=nixos rd.debug rd.shell rd.break=mount
        initrd ($rootfs)/nix/var/nix/profiles/system/initrd
      }
    }
  '';
  grubSerialConsoleConfig = ''
    # Keep GRUB output visible on both local console and serial capture.
    serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
    terminal_input console serial
    terminal_output console serial
  '';
in
{
  config = {
    # Boot configuration
    boot = {

      inherit kernelModules supportedFilesystems;

      loader = {
        grub = {
          device = "nodev";
          efiSupport = true;
          efiInstallAsRemovable = true;
          timeoutStyle = if bootstrapMode then "menu" else "countdown";
          extraConfig =
            grubSerialConsoleConfig
            + lib.optionalString bootstrapDebug ''
              # Pause in GRUB until an operator selects an entry.
              set timeout=-1
            '';
          extraEntries = grubExerciseEntries;
        };
        timeout = lib.mkForce (
          if bootstrapDebug then
            15
          else if bootstrapMode then
            3
          else
            0
        );
      };

      kernelParams =
        [
          "console=hvc0" # Use hvc0 for console output in VZ
          "console=ttyAMA0" # Keep early serial output visible for aarch64 EFI/QEMU-style consoles
          "console=ttyS0" # Additional fallback serial console
          "console=tty1" # Also show console/getty on the graphical console
          "systemd.show_status=1"
          "rd.systemd.show_status=1"
        ]
        ++ (lib.optionals bootstrapMode [
          "logo.nologo"
          "rootwait"
          "rootdelay=5"
        ])
        ++ (lib.optionals bootstrapDebug [
          "loglevel=7"
          "ignore_loglevel"
          "rd.udev.log_level=debug"
          "boot.shell_on_fail"
          "boot.trace"
        ]);

      plymouth.enable = lib.mkForce (if bootstrapMode then false else true);

      kernel.sysctl = {
        "net.bridge.bridge-nf-call-ip6tables" = 1;
        "net.bridge.bridge-nf-call-iptables" = 1;
        "net.bridge.bridge-nf-call-arptables" = 1;
        "net.core.devconf_inherit_init_net" = 1;
      };

      loader.systemd-boot.enable = lib.mkForce false; # Prefer GRUB EFI path for Lima raw-efi guests
      loader.efi.canTouchEfiVariables = lib.mkForce false;

      # verbosity (default off; override per-host if needed)
      consoleLogLevel =
        if bootstrapDebug then
          lib.mkForce 7
        else if bootstrapMode then
          lib.mkForce 4
        else
          lib.mkDefault consoleCfg.logLevel;
      initrd = {
        inherit kernelModules supportedFilesystems;

        enable = true;
        verbose = true;
        availableKernelModules = [
          "virtio_pci"
          "virtio_blk"
          "virtio_scsi"
          "virtio_net"
          "virtio_mmio"
          "nvme"
        ];
      };

      postBootCommands = ''
        chmod 755 /boot || true
        chmod 600 /boot/loader/.#bootctlrandom-seed* 2>/dev/null || true
      '';
    };
  };
}