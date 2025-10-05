{ config, pkgs, lib, containerRegistrySystem, ... }:

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
in {
  imports = [
    ../common
    ./firewall.nix
    ./networking-mammoth-skate.nix
    ./dnsmasq.nix
    ./code-server.nix
    ./container-host.nix
    ./containers
    ./disko.nix
    ./incus.nix
    ./podman.nix
    ./systemd
    ./tailscale.nix
    ./zfs.nix
    #(import ./remote-nix-store.nix { inherit config pkgs lib; })
    #(import ./nix-snapshotter.nix { inherit config pkgs lib user; })
    # Explicitly disable GPG in NixOS - agent is forwarded from Darwin host
    ({ config, ... }: {
      hm.imports = config.hm.imports ++ [ ./enable-gpg-false.nix ];
    })
  ];

  nix.settings = lib.mkMerge [
    {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ cfgUserName "root" ];
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
        "https://aseipp-nix-cache.freetls.fastly.net"  # Fastly Cache v2 (tried first)
        "https://cache.flox.dev" 
        "https://nxmatic.cachix.org"  # nxmatic cache
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="  # Required for mirrors
        "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="
        "nxmatic.cachix.org-1:huMghYiwDpPa1PMXHXK4G1Dp4QOZjgsNqxcjf/AjuJ0="  # nxmatic key
      ];
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
      # "console=tty1" # Use tty1 for console output in qemu
      "loglevel=7"
      "systemd.log_level=debug"
      "systemd.log_target=console"
      "udev.log_priority=debug"
      "boot.trace"
      "rd.systemd.unit=rescue.target"
      "rd.systemd.debug_shell=1"
    ];

    kernel.sysctl = {
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-arptables" = 1;
      "net.core.devconf_inherit_init_net" = 1;
    };

    loader.systemd-boot.enable = true; # (for UEFI systems only)

    # verbosity
    consoleLogLevel = 7;
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
  } // lib.mkIf (!config.disko.enableConfig) {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      autoResize = true;
      fsType = "ext4";
      options = [ "noatime" "nodiratime" "discard" ];
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

  environment.systemPackages = with pkgs; [ disko zfs binutils ];
  
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
    journald.extraConfig = ''
      ForwardToConsole=yes
      TTYPath=/dev/console
      MaxLevelConsole=debug
    '';
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

  # Security
  security.sudo.enable = true;
  security.sudo.wheelNeedsPassword = false;

  # User configuration: derive flags based on UID threshold (<1000 => system user)
  user = lib.mkForce (
    let
      base = builtins.removeAttrs cfgUser [ "gid" "group" "isNormalUser" "isSystemUser" ];
      low = cfgUser.uid != null && cfgUser.uid < 1000;
    in
    base // {
      isNormalUser = !low;
      isSystemUser = low;
    }
  );

  users.users.${cfgUserName} = {
    group = cfgUserName;
    extraGroups = [ "wheel" "ssh" ];
    uid = lib.mkIf (cfgUser.uid != null) cfgUser.uid;
  };
  users.groups.${cfgUserName} = lib.mkIf (cfgUser.gid != null) { gid = cfgUser.gid; };

}
