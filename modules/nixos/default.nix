{
  config,
  pkgs,
  lib,
  hostProfile ? { },
  catalog,
  ...
}:

let
  kernelModules = [
    "nfsd"
    "ext4"
    "overlay"
    "isofs"
    "sunrpc"
    "nls_cp437"
    "nls_iso8859_1"
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
    "nft_chain_nat"
    "nft_masq"
    "nft_redir"
    "nfnetlink"
    "xt_conntrack"
  ];
  supportedFilesystems = {
    ext4 = true;
    overlay = true;
    iso9660 = true;
  };
  # Generate a hostId (should be a 4-byte hex string, e.g. from `head -c4 /dev/urandom | od -A none -t x4`)
  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;
  cfgUserIsNormal = cfgUser.isNormalUser or true;
  cfgUidLow = cfgUser.uid != null && cfgUser.uid < 1000;
  cfgGidLow = cfgUser.gid != null && cfgUser.gid < 1000;
  nixosUserUid = if cfgUserIsNormal && cfgUidLow then null else cfgUser.uid;
  nixosUserGid = if cfgUserIsNormal && cfgGidLow then null else cfgUser.gid;
  consoleCfg = config.consoleLogging;
  cacheCatalog = catalog.caches;
  hostImageMode = hostProfile.nixosImageMode or "full";
  nixosBootLoader = hostProfile.nixosBootLoader or "grub";
  useSystemdBoot = nixosBootLoader == "systemd-boot";
  useGrub = !useSystemdBoot;
  bootstrapMode = hostImageMode == "bootstrap";
  # Canonical behavior: bootstrap image mode implies bootstrap debug profile.
  bootstrapDebug = bootstrapMode;
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
  bootstrapRequiredImports = [
    ../.common.d
    ./etc-backup.nix
    ./lima-network-interfaces.nix
    ./disko.nix
    ./systemd
    ./zfs.nix
    ./sops.nix
  ];

  runtimeOnlyImports = [
    ./firewall.nix
    ./networking-mammoth-skate.nix
    ./vlan.nix
    ./cachix-watch-store.nix
    ./container-host.nix
    # ./containers
    ./dbus-tcp.nix
    ./headscale.nix
    ./nix-ld.nix
    ./tailscale.nix
    ./resolved-lan.nix
    ./dnsmasq.nix
    ./avahi.nix
    ./code-server.nix
    ./nfs-autofs.nix
    ./incus.nix
    ./podman.nix
  ];
in
{
  options.consoleLogging = {
    forwardToConsole = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Forward journald messages to the console.";
    };

    logLevel = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Kernel/console log level (0=emerg, 7=debug).";
    };
  };
  imports =
    bootstrapRequiredImports
    ++ (lib.optionals (!bootstrapMode) runtimeOnlyImports)
    ++ (lib.optionals (!bootstrapMode) [
    #(import ./remote-nix-store.nix { inherit config pkgs lib; })
    #(import ./nix-snapshotter.nix { inherit config pkgs lib user; })
    # Explicitly disable GPG in NixOS - agent is forwarded from Darwin host
    (
      { config, ... }:
      {
        hm.imports = config.hm.imports ++ [ ./enable-gpg-false.nix ];
      }
    )
    ]);

  config = {

    # Explicit NDH bootstrap profile policy by image mode:
    # - bootstrap images: non-strict runtime (warn) to avoid deadlocks while first boot converges
    # - full/runtime images: strict contract enforced
    nxmatic.bootstrapProfile.requireForActivation = lib.mkDefault (!bootstrapMode);
    nxmatic.bootstrapProfile.autoInstallOnActivation = lib.mkDefault true;

    activation.postActivationLogShowLabel = "journald (last 2h)";
    activation.postActivationLogShowCmd = "journalctl --since '2 hours ago' -o short-precise -t darwin.activationScripts -t home-manager.activationScripts";
    activation.postActivationLogStreamLabel = "journald (follow)";
    activation.postActivationLogStreamCmd = "journalctl -f -o short-precise -t darwin.activationScripts -t home-manager.activationScripts";

    nix.settings = lib.mkMerge [
      {
        # Enable content-addressed derivations to reduce rebuild churn for identical outputs.
        # We also disable auto-optimise-store for faster iterative builds; run `nix-store --optimise` manually when idle.
        experimental-features = [
          "nix-command"
          "flakes"
          "ca-derivations"
        ];
        auto-optimise-store = false; # Manual optimise recommended; improves build latency during development.
        trusted-users = [
          cfgUserName
          "root"
        ];
        sandbox = false;
        extra-sandbox-paths = [ "/dev/kvm" ];

        # Cache settings with Fastly CDN for faster downloads
        # Using 'substituters' (not 'extra-substituters') to control order
        # Alternative caches (uncomment one to use):
        # - "${cacheCatalog.nixos.substituter}"                                  # Official NixOS cache (default)
        # - "${cacheCatalog.aseippFastly.substituter}"              # Fastly Cache v2 (recommended, faster) - currently active
        # - "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"  # Tsinghua University (China)
        # - "https://mirrors.ustc.edu.cn/nix-channels/store"           # USTC (China)
        # - "https://mirrors.bfsu.edu.cn/nix-channels/store"           # BFSU (China)
        substituters = [
          cacheCatalog.aseippFastly.substituter # Fastly Cache v2 (tried first)
          cacheCatalog.nxmatic.substituter # nxmatic cache
        ];
        trusted-public-keys = [
          cacheCatalog.nixos.publicKey # Required for mirrors
          cacheCatalog.nxmatic.publicKey # nxmatic key
        ];
        # NOTE (@codebase): Rollback instructions:
        #   - Remove "ca-derivations" from experimental-features.
        #   - Set auto-optimise-store = true to restore inline dedup.
        # Validation:
        #   - Check a new build's store path naming stability when spec changes trivially.
        #   - Run `nix-store --optimise --dry-run` after several builds to assess dedup benefit.
      }
    ];

    nix.extraOptions = ''
      !include /etc/nix/nix.custom.conf
    '';

    # Boot configuration
    boot = {

      # Use an immutable store path for PID1 handoff in stage-2.
      # This avoids early-boot dependency on /run/current-system being present.
      systemdExecutable = "${config.systemd.package}/lib/systemd/systemd";

      inherit kernelModules supportedFilesystems;

      loader = {
        grub = {
          enable = lib.mkForce useGrub;
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

      kernelParams = lib.mkMerge [
        [
          "console=hvc0" # Keep serial console output in VZ
          "console=ttyAMA0" # Keep early serial output visible for aarch64 EFI/QEMU-style consoles
          "console=ttyS0" # Additional fallback serial console
          "systemd.show_status=1"
          "rd.systemd.show_status=1"
        ]
        (lib.optionals bootstrapMode [
          "logo.nologo"
          "rootwait"
          "rootdelay=5"
        ])
        (lib.optionals bootstrapDebug [
          "loglevel=7"
          "ignore_loglevel"
          "rd.udev.log_level=debug"
          "boot.shell_on_fail"
          # Enables `set -x` in stage-2 init script for exact command tracing.
          "boot.debugtrace"
          "boot.trace"
        ])
        # Keep tty1 plus runtime debug overrides at the end so they win against
        # upstream defaults contributed by other modules (e.g. loglevel=0).
        (lib.mkAfter (
          [ "console=tty1" ]
          ++ (lib.optionals (!bootstrapMode) [
            "loglevel=7"
            "ignore_loglevel"
            # Keep stage-2 command trace enabled while diagnosing PID1 exit 127.
            "boot.debugtrace"
          ])
        ))
      ];

      kernel.sysctl = {
        "net.bridge.bridge-nf-call-ip6tables" = 1;
        "net.bridge.bridge-nf-call-iptables" = 1;
        "net.bridge.bridge-nf-call-arptables" = 1;
        "net.core.devconf_inherit_init_net" = 1;
      };

      loader.systemd-boot.enable = lib.mkForce useSystemdBoot;
      loader.systemd-boot.configurationLimit = lib.mkIf useSystemdBoot (lib.mkDefault 8);
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
        if [ ! -e /run/current-system ] && [ -e /run/booted-system ]; then
          ln -s /run/booted-system /run/current-system
        fi
      '';
    };

    system.stateVersion = "25.11"; # Update this when upgrading NixOS

    fileSystems = {
      "/boot" = {
        device = lib.mkForce "/dev/vda1"; # /dev/disk/by-label/ESP in nixos-lima upstream
        fsType = "vfat";
        options = [
          "rw"
          "relatime"
          "fmask=0022"
          "dmask=0022"
          "codepage=437"
          "iocharset=iso8859-1"
          "shortname=mixed"
          "errors=remount-ro"
        ];
      };
    }
    // lib.mkIf (!config.disko.enableConfig) {
      "/" = {
        device = "/dev/disk/by-label/nixos";
        autoResize = true;
        fsType = "ext4";
        options = [
          "noatime"
          "nodiratime"
          "discard"
        ];
      };
      "/tmp" = {
        device = "/var/tmp";
        options = [ "bind" ];
      };
    };

    limaHost.isGuest = true;

    networking = {
      hostId = "deadbeef";
      # Canonical policy: firewall disabled on NixOS lab hosts.
      firewall.enable = lib.mkForce false;
    }
    // (lib.optionalAttrs (!bootstrapMode) {
      mammoth-skate.enable = lib.mkDefault (!bootstrapMode);
    });

    # Remove or comment out the old networking block to avoid conflicts:
    # networking = { ... }

    environment.systemPackages =
      [
        pkgs.binutils
        pkgs.disko
      ]
      ++ (lib.optionals (!bootstrapMode) (with pkgs; [
        autofs5 # Explicitly include autofs utilities @codebase
        zfs
        incus
        distrobuilder
        nssmdns # Ensure mDNS resolution via NSS @codebase
      ]));

    # Ensure security wrappers are in PATH for all processes
    environment.variables = {
      PATH = lib.mkBefore [ "/run/wrappers/bin" ];
    };

    # Also set it in the shell init
    # environment.shellInit = ''
    #   export PATH="/run/wrappers/bin:$PATH"
    # '';

    # Services
    services.getty.autologinUser = "root";
    services.nxmaticCachixWatchStore.enable = lib.mkDefault (!bootstrapMode);
    services.ntopng = {
      enable = lib.mkDefault (!bootstrapMode);
      interfaces = [ "all" ];
      extraConfig = ''
        -i all
        --dns-mode none
        --http-port 3000
        --http-interface
        --http-user admin
        --http-password admin
      '';
    };

    # Journald (console logging controls)
    services.journald.console = lib.mkForce "/dev/console";
    services.journald.extraConfig = ''
      # Console forwarding disabled by default; set consoleLogging.forwardToConsole = true to write to /dev/console
    '';

    # Security
    security.sudo.enable = true;
    security.sudo.wheelNeedsPassword = false;

    # Ensure getties on key consoles, with autologin for rescue/multi-user
    systemd.services."getty@tty1" = {
      enable = true;
      wantedBy = [
        "rescue.target"
        "multi-user.target"
      ];
      serviceConfig.ExecStart = lib.mkForce "${pkgs.util-linux}/sbin/agetty --autologin root --noclear tty1 linux";
    };

    systemd.services."serial-getty@hvc0".enable = lib.mkForce false;
    systemd.services."serial-getty@ttyAMA0".enable = true;
    systemd.services."serial-getty@ttyS0".enable = true;

    # Preserve profile-provided user kind flags.
    # For normal users, do not force low Darwin-style IDs (<1000) on NixOS,
    # because NixOS asserts that normal users must use UID >= 1000.
    # We keep the user normal (for Home Manager activation) and let NixOS
    # allocate a compliant uid/gid when profile ids are below the NixOS range.
    user = lib.mkForce (
      builtins.removeAttrs cfgUser [
        "uid"
        "gid"
        "group"
      ]
    );

    users.users.${cfgUserName} = {
      group = cfgUserName;
      extraGroups = [
        "keys"
        "wheel"
        "ssh"
      ];
      uid = lib.mkIf (nixosUserUid != null) nixosUserUid;
    };
    users.groups.${cfgUserName} = if nixosUserGid != null then { gid = nixosUserGid; } else { };

    # Debug convenience: set root password to "root" (insecure; remove when done)
    users.users.root.initialPassword = "root";

  };

}
