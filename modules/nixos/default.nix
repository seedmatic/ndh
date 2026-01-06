{
  config,
  pkgs,
  lib,
  containerRegistrySystem,
  ...
}:

let
  isX86_64 = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
  isAarch64 = pkgs.stdenv.hostPlatform.system == "aarch64-linux";
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
  consoleCfg = config.consoleLogging;
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
  imports = [
    ../common
    ./firewall.nix
    ./lima-network-interfaces.nix
    ./networking-mammoth-skate.nix
    ./dnsmasq.nix
    ./avahi.nix
    ./code-server.nix
    ./container-host.nix
    ./containers
    ./disko.nix
    ./headscale-server.nix
    ./headscale-client.nix
    ./headscale-gateway.nix
    ./nfs-autofs.nix
    ./incus.nix
    ./incus-headscale-server.nix
    ./incus-headscale-gateway.nix
    ./incus-tailscale-gateway.nix
    ./nix-ld.nix
    ./podman.nix
    ./systemd
    ./tailscale.nix
    # Teleport removed - using Headscale/Tailscale SSH
    ./zfs.nix
    #(import ./remote-nix-store.nix { inherit config pkgs lib; })
    #(import ./nix-snapshotter.nix { inherit config pkgs lib user; })
    # Explicitly disable GPG in NixOS - agent is forwarded from Darwin host
    (
      { config, ... }:
      {
        hm.imports = config.hm.imports ++ [ ./enable-gpg-false.nix ];
      }
    )
  ];

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
        # - "https://cache.nixos.org"                                  # Official NixOS cache (default)
        # - "https://aseipp-nix-cache.freetls.fastly.net"              # Fastly Cache v2 (recommended, faster) - currently active
        # - "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"  # Tsinghua University (China)
        # - "https://mirrors.ustc.edu.cn/nix-channels/store"           # USTC (China)
        # - "https://mirrors.bfsu.edu.cn/nix-channels/store"           # BFSU (China)
        substituters = [
          "https://aseipp-nix-cache.freetls.fastly.net" # Fastly Cache v2 (tried first)
          "https://nxmatic.cachix.org" # nxmatic cache
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" # Required for mirrors
          "nxmatic.cachix.org-1:huMghYiwDpPa1PMXHXK4G1Dp4QOZjgsNqxcjf/AjuJ0=" # nxmatic key
        ];
        # NOTE (@codebase): Rollback instructions:
        #   - Remove "ca-derivations" from experimental-features.
        #   - Set auto-optimise-store = true to restore inline dedup.
        # Validation:
        #   - Check a new build's store path naming stability when spec changes trivially.
        #   - Run `nix-store --optimise --dry-run` after several builds to assess dedup benefit.
      }
      (lib.mkIf isX86_64 {
        extra-platforms = [ "aarch64-linux" ];
        extra-sandbox-paths = [ "/run/binfmt" ];
      })
      (lib.mkIf isAarch64 { extra-platforms = [ "x86_64-linux" ]; })
    ];

  # Boot configuration
  boot = {

    inherit kernelModules supportedFilesystems;

    binfmt.emulatedSystems = lib.mkMerge [
      (lib.mkIf isX86_64 [ "aarch64-linux" ])
      (lib.mkIf isAarch64 [ "x86_64-linux" ])
    ];

    loader = {
      grub = {
        device = "nodev";
        efiSupport = true;
        efiInstallAsRemovable = true;
      };
      timeout = lib.mkForce 0;
    };

    kernelParams = [
      "console=hvc0" # Use hvc0 for console output in VZ
      "console=tty1" # Also show console/getty on the graphical console
      "boot.trace"
    ];

    kernel.sysctl = {
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-arptables" = 1;
      "net.core.devconf_inherit_init_net" = 1;
    };

    loader.systemd-boot.enable = true; # (for UEFI systems only)

    # verbosity (default off; override per-host if needed)
    consoleLogLevel = lib.mkDefault consoleCfg.logLevel;
    initrd = {
      inherit kernelModules supportedFilesystems;

      enable = true;
      verbose = true;
    };

    postBootCommands = ''
      chmod 755 /boot || true
      chmod 600 /boot/loader/.#bootctlrandom-seed* 2>/dev/null || true
    '';
  };

  system.stateVersion = "25.05"; # Update this when upgrading NixOS

  fileSystems = {
    "/boot" = {
      device = "/dev/disk/by-label/ESP";
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
    mammoth-skate.enable = true;
  };

  # Remove or comment out the old networking block to avoid conflicts:
  # networking = { ... }

  environment.systemPackages = with pkgs; [
    disko
    zfs
    binutils
    incus
    distrobuilder
  ];

  # Ensure security wrappers are in PATH for all processes
  environment.variables = {
    PATH = lib.mkBefore [ "/run/wrappers/bin" ];
  };

  # Also set it in the shell init
  # environment.shellInit = ''
  #   export PATH="/run/wrappers/bin:$PATH"
  # '';

  # Services
  services = {
    getty.autologinUser = "root";
    ntopng = {
      enable = true;
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
  };

  # Journald (console logging controls)
  services.journald.console = lib.mkDefault (
    if consoleCfg.forwardToConsole then "/dev/console" else ""
  );
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

  systemd.services."serial-getty@hvc0" = {
    enable = true;
    wantedBy = [
      "rescue.target"
      "multi-user.target"
    ];
    unitConfig.ConditionPathExists = "/dev/hvc0";
    serviceConfig.ExecStart = lib.mkForce "${pkgs.util-linux}/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 --noclear hvc0 linux";
  };

  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [
      "rescue.target"
      "multi-user.target"
    ];
    unitConfig.ConditionPathExists = "/dev/ttyS0";
    serviceConfig.ExecStart = lib.mkForce "${pkgs.util-linux}/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 --noclear ttyS0 vt220";
  };

  # User configuration: derive flags based on UID threshold (<1000 => system user)
  user = lib.mkForce (
    let
      base = builtins.removeAttrs cfgUser [
        "gid"
        "group"
        "isNormalUser"
        "isSystemUser"
      ];
      low = cfgUser.uid != null && cfgUser.uid < 1000;
    in
    base
    // {
      isNormalUser = !low;
      isSystemUser = low;
    }
  );

  users.users.${cfgUserName} = {
    group = cfgUserName;
    extraGroups = [
      "wheel"
      "ssh"
    ];
    uid = lib.mkIf (cfgUser.uid != null) cfgUser.uid;
  };
  users.groups.${cfgUserName} = lib.mkIf (cfgUser.gid != null) { gid = cfgUser.gid; };

  # Debug convenience: set root password to "root" (insecure; remove when done)
  users.users.root.initialPassword = "root";

  };

}
