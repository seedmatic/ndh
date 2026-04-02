{
  config,
  pkgs,
  lib,
  hostProfile ? { },
  containerRegistrySystem,
  catalog,
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
  hostImageMode =
    if hostProfile ? nixosImageMode && hostProfile.nixosImageMode != null then
      hostProfile.nixosImageMode
    else
      "full";
  bootstrapMode = hostImageMode == "bootstrap";
  bootstrapDebug =
    bootstrapMode
    && (if hostProfile ? bootstrapDebug && hostProfile.bootstrapDebug != null then hostProfile.bootstrapDebug else false);
  baseImports = [
    ../common
    ./firewall.nix
    ./lima-network-interfaces.nix
    ./networking-mammoth-skate.nix
    ./vlan.nix
    ./cachix-watch-store.nix
    ./container-host.nix
    ./containers
    ./disko.nix
    ./dbus-tcp.nix
    ./headscale-client.nix
    ./nix-ld.nix
    ./systemd
    ./tailscale.nix
    ./zfs.nix
  ];
  fullOnlyImports = [
    ./resolved-lan.nix
    ./dnsmasq.nix
    ./avahi.nix
    ./code-server.nix
    ./headscale-server.nix
    ./headscale-gateway.nix
    ./nfs-autofs.nix
    ./incus.nix
    ./incus-headscale-server.nix
    ./incus-headscale-gateway.nix
    ./incus-tailscale-gateway.nix
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
    baseImports
    ++ (lib.optionals (!bootstrapMode) fullOnlyImports)
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

    activation.loggerCmd = lib.mkDefault "${pkgs.util-linux}/bin/logger -p notice -t %TAG%";

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

      inherit kernelModules supportedFilesystems;

      loader = {
        grub = {
          device = "nodev";
          efiSupport = true;
          efiInstallAsRemovable = true;
        };
        timeout = lib.mkForce (if bootstrapMode then 3 else 0);
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
      consoleLogLevel = lib.mkDefault consoleCfg.logLevel;
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

    system.stateVersion = "25.05"; # Update this when upgrading NixOS

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
      mammoth-skate.enable = lib.mkDefault (!bootstrapMode);
    };

    # Remove or comment out the old networking block to avoid conflicts:
    # networking = { ... }

    environment.systemPackages =
      [ pkgs.binutils ]
      ++ (lib.optionals (!bootstrapMode) (with pkgs; [
        autofs5 # Explicitly include autofs utilities @codebase
        disko
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

    systemd.services."serial-getty@hvc0".enable = true;
    systemd.services."serial-getty@ttyAMA0".enable = true;

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
