{
  config,
  pkgs,
  lib,
  options,
  ndh,
  ...
}:

let
  # Boot/runtime kernel capabilities shared by stage1+stage2.
  kernelModules = [
    "nfs"
    "ext4"
    "btrfs"
    "overlay"
    "isofs"
    "sunrpc"
    "lockd"
    "nfsd"
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
  supportedFilesystems = [
    "ext4"
    "btrfs"
    "overlay"
    "iso9660"
    "nfs"
    "nfs4"
  ];

  # Profile/user identity normalization for NixOS constraints.
  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;
  cfgUserIsNormal = cfgUser.isNormalUser or true;
  cfgUidLow = cfgUser.uid != null && cfgUser.uid < 1000;
  cfgGidLow = cfgUser.gid != null && cfgUser.gid < 1000;
  nixosUserUid = if cfgUserIsNormal && cfgUidLow then null else cfgUser.uid;
  nixosUserGid = if cfgUserIsNormal && cfgGidLow then null else cfgUser.gid;
  ndhContext = ndh.context;
  consoleCfg = config.consoleLogging;
  hostProfile = ndhContext.hostProfile;
  generationMode = ndhContext.generationMode;
  catalog = ndhContext.catalog;
  cacheCatalog = catalog.caches;
  rke2labNetplan = lib.attrByPath [ "netplan" "rke2lab" ] { } catalog;
  clusterName = hostProfile.hostName or null;
  clusterNetwork =
    if clusterName != null then lib.attrByPath [ "clusters" clusterName ] null rke2labNetplan else null;

  # Boot mode selection.
  nixosBootLoader = hostProfile.nixosBootLoader or "grub";
  useSystemdBoot = nixosBootLoader == "systemd-boot";
  useGrub = !useSystemdBoot;
  isTartProvider = (lib.attrByPath [ "ndh" "vm" "provider" ] "lima" config) == "tart";
  # Optional host override for debug verbosity.
  # Canonical default: bringup images are interactive-first (tty prompt usable)
  # unless debug is explicitly requested.
  bootDebug = hostProfile.nixosBootstrapDebug or false;
  # Canonical rule: generationMode controls bringup/runtime behavior.
  bringupMode = generationMode == "bringup";
  runtimeMode = !bringupMode;

  rootUserName = "root";
  virtualSerialConsole = "hvc0";
  videoDisplayConsole = "tty0";
  journaldConsoleDevice = "/dev/console"; # if bringupMode then "/dev/${virtualSerialConsole}" else "/dev/console";
  journaldConsoleLevel = if bootDebug then "debug" else "info";
  systemdManagerShowStatusNo = {
    # Don't clobber the console with duplicate systemd messages.
    ShowStatus = "no";
  };
  mkBringupOverride = value: if bringupMode then lib.mkForce value else value;

  # Root filesystem/mount policy.
  bringupRootFsType = config.profile.host.nixosBringupRootFs;
  ext4RootMountOptions = [
    "noatime"
    "nodiratime"
    "discard"
    "x-systemd.growfs"
  ];
  zstdLevel = hostProfile.nixosZstdCompressionLevel or 1;
  btrfsRootMountOptions = [
    "noatime"
    "compress=zstd:${toString zstdLevel}"
    "space_cache=v2"
    "discard=async"
    "x-systemd.growfs"
  ];
  rootFsType = if bringupMode then bringupRootFsType else "ext4";
  rootFsMountOptions = if rootFsType == "btrfs" then btrfsRootMountOptions else ext4RootMountOptions;
  builderKeys = builtins.fromJSON (
    builtins.readFile (
      pkgs.runCommand "ndh-linux-builder-keys.json" { buildInputs = [ pkgs.yq-go ]; } ''
        yq -o=json '.' ${../home-manager/ssh.d/keys.yaml} > "$out"
      ''
    )
  );
  initrdRescueAuthorizedKeys = lib.unique (
    lib.filter (key: key != "") (
      [
        (
          if
            builderKeys ? profiles
            && builderKeys.profiles ? committed
            && builderKeys.profiles.committed ? linux-builder
            && builderKeys.profiles.committed.linux-builder ? public
          then
            "ssh-ed25519 ${builderKeys.profiles.committed.linux-builder.public} committed-linux-builder"
          else
            ""
        )
        (
          if
            builderKeys ? profiles
            && builderKeys.profiles ? work
            && builderKeys.profiles.work ? linux-builder
            && builderKeys.profiles.work.linux-builder ? public
          then
            "ssh-ed25519 ${builderKeys.profiles.work.linux-builder.public} work-linux-builder"
          else
            ""
        )
      ]
      ++ (config.users.users.root.openssh.authorizedKeys.keys or [ ])
      ++ (config.users.users.${cfgUserName}.openssh.authorizedKeys.keys or [ ])
    )
  );
  initrdRescueSshHostKey =
    pkgs.runCommand "ndh-initrd-rescue-ssh-hostkey" { nativeBuildInputs = [ pkgs.openssh ]; }
      ''
        install -d "$out"
        ssh-keygen -q -t ed25519 -N "" -C "initrd-rescue@${cfgUserName}" -f "$out/ssh_host_ed25519_key" >/dev/null
      '';
  initrdRescueSshHostKeyInInitrd = "/etc/secrets/initrd/ssh_host_ed25519_key";
  initrdRescueSshHostKeyStorePath = initrdRescueSshHostKey + "/ssh_host_ed25519_key";
  kernelConsoleParams = [
    "console=${videoDisplayConsole}"
    "console=${virtualSerialConsole}"
  ];

  # GRUB exercise/debug menu fragments.
  grubDebugKernelParams = lib.concatStringsSep " " (
    [
      "init=/nix/var/nix/profiles/system/init"
      "logo.nologo"
      "rootwait"
      "rootdelay=5"
      "consoleLoglevel=7"
      "udev.log_level=err"
      "boot.trace"
    ]
    ++ kernelConsoleParams
  );
  grubExerciseEntries = lib.optionalString bootDebug ''
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
    ./dbus-tcp.nix
    ./vlan.nix
    ./tailscale.nix
  ];

  runtimeOnlyImports = [
    ./nixos-reduction.nix
    ./networking-mammoth-skate.nix
    ./cachix-watch-store.nix
    ./container-host.nix
    ./headscale.nix
    ./nix-ld.nix
    ./resolved-lan.nix
    ./dnsmasq.nix
    ./avahi.nix
    ./code-server.nix
    ./nfs-autofs.nix
    ./incus.nix
    ./podman.nix
  ];
  runtimeExtraSystemPackages = with pkgs; [
    autofs5 # Explicitly include autofs utilities @codebase
    zfs
    incus
    distrobuilder
    nssmdns # Ensure mDNS resolution via NSS @codebase
  ];
  nixosUserExtraGroups = [
    "keys"
    "wheel"
    "ssh"
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
    ++ (lib.optionals runtimeMode runtimeOnlyImports)
    ++ (lib.optionals runtimeMode [
      #(import ./remote-nix-store.nix { inherit config pkgs lib; })
      #(import ./nix-snapshotter.nix { inherit config pkgs lib user; })
      # Explicitly disable GPG in NixOS - agent is forwarded from Darwin host
      (
        { lib, ... }:
        {
          home-manager.users.${cfgUserName}.imports = [ ./enable-gpg-false.nix ];
        }
      )
    ]);

  config = {

    # Explicit NDH bootstrap profile policy by image mode:
    # - bootstrap images: non-strict runtime (warn) to avoid deadlocks while first boot converges
    # - full/runtime images: strict contract enforced
    ndh.bringupRuntime.requireForActivation = lib.mkDefault runtimeMode;
    ndh.bringupRuntime.autoInstallOnActivation = lib.mkDefault true;

    # Temporary troubleshooting toggle: disable /etc backup activation script
    # to isolate boot/login issues from activation-time backup behavior.
    ndh.etcBackup.enable = lib.mkForce false;

    activation.postActivationLogShowLabel = "journald (last 2h)";
    activation.postActivationLogShowCmd = "journalctl --since '2 hours ago' -o short-precise -t darwin.activationScripts -t home-manager.activationScripts";
    activation.postActivationLogStreamLabel = "journald (follow)";
    activation.postActivationLogStreamCmd = "journalctl -f -o short-precise -t darwin.activationScripts -t home-manager.activationScripts";

    # Provide POSIX-style compatibility path for scripts that expect /usr/bin/env.
    # Run as early as possible in activation to unblock downstream script shebangs.
    system.activationScripts."00nxmaticUsrBinEnv" = {
      deps = [ "specialfs" ];
      supportsDryActivation = false;
      text = ''
        set -eu

        install -d -m 0755 /usr/bin
        ln -sfn ${pkgs.coreutils}/bin/env /usr/bin/env
      '';
    };

    nix.settings = {
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
        rootUserName
        "builder" # remote builder user (nerd-nixos Lima VM)
      ];
      sandbox = false;
      # Keep sandbox disabled for this profile set; do not force host-local
      # device paths (e.g. /dev/kvm) into evaluated settings, as that breaks
      # evaluation on non-KVM bringup/runtime hosts.

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
    };

    nix.extraOptions = ''
      !include /etc/nix/nix.custom.conf
    '';

    # Boot configuration
    boot = {

      plymouth = {
        enable = true;
        theme = "rings";
        themePackages = with pkgs; [
          (adi1090x-plymouth-themes.override { selected_themes = [ "rings" ]; })
        ];
      };

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
          timeoutStyle = if bootDebug then "menu" else "countdown";
          extraConfig =
            grubSerialConsoleConfig
            + lib.optionalString bootDebug ''
              # Pause in GRUB until an operator selects an entry.
              set timeout=-1
            '';
          extraEntries = grubExerciseEntries;
        };
        timeout = lib.mkForce (
          if bringupMode then
            0
          else if bootDebug then
            15
          else
            5
        );
      };

      kernelParams = lib.mkMerge [
        (
          [
            # Kernel cmdline journald routing:
            # - rd.systemd.* applies in initrd (early boot stage before switch_root)
            # - systemd.* applies in stage-2 (real root userspace)
            # Keep both for consistent serial visibility across bootstrap.
            "rd.systemd.journald.forward_to_console=1"
            # "rd.systemd.journald.console=/dev/${virtualSerialConsole}"
            "systemd.journald.forward_to_console=1"
            # "systemd.journald.console=/dev/${virtualSerialConsole}"
          ]
          ++ kernelConsoleParams
        )
        (lib.optionals (!bringupMode || bootDebug) [
          "rootwait"
          "rootdelay=5"
        ])
        (lib.optionals bootDebug [
          "loglevel=7"
          "rd.udev.log_level=err"
          "udev.log_level=err"
          "boot.shell_on_fail"
          "boot.debugtrace"
          "boot.trace"
          #"boot.debug1"
          #"boot.debug1mounts"
          "systemd.log_level=debug"
        ])
      ];

      kernel.sysctl = {
        "net.bridge.bridge-nf-call-ip6tables" = 1;
        "net.bridge.bridge-nf-call-iptables" = 1;
        "net.bridge.bridge-nf-call-arptables" = 1;
        "net.core.devconf_inherit_init_net" = 1;
      };

      loader.systemd-boot.enable = lib.mkForce useSystemdBoot;
      loader.systemd-boot.configurationLimit = lib.mkIf useSystemdBoot (lib.mkDefault 3);
      loader.efi.canTouchEfiVariables = lib.mkForce false;

      # verbosity (default off; override per-host if needed)
      consoleLogLevel =
        if bootDebug then
          lib.mkForce 7
        else if bringupMode then
          lib.mkForce 4
        else
          lib.mkDefault consoleCfg.logLevel;

      initrd = {
        inherit kernelModules supportedFilesystems;

        network = lib.mkIf bringupMode {
          enable = true;
          ssh = {
            enable = initrdRescueAuthorizedKeys != [ ];
            port = 22;
            hostKeys = [ initrdRescueSshHostKeyInInitrd ];
            authorizedKeys = initrdRescueAuthorizedKeys;
          };
        };

        secrets = lib.mkIf bringupMode {
          # initrd-ssh.nix also defines this key as a self-map (path -> same path).
          # We intentionally override with (initrd path -> generated store key path).
          "${initrdRescueSshHostKeyInInitrd}" = lib.mkForce initrdRescueSshHostKeyStorePath;
        };

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
        systemd = {
          enable = true;
          # gpt-auto root discovery is needed for non-ZFS bringup (Discoverable
          # Partitions Spec). ZFS uses zfs-import instead — gpt-auto causes a 90s
          # initrd timeout waiting for /dev/gpt-auto-root on ZFS roots.
          root = lib.mkIf (rootFsType != "zfs") (lib.mkForce "gpt-auto");
          network.enable = lib.mkDefault bringupMode;
          emergencyAccess = true;
          # Recovery/forensics toolset always present in the initrd emergency shell.
          # Available in both bringup and runtime modes so any host can be debugged
          # when dropped to stage-1 via `rd.break`, `emergency.target`, or a boot failure.
          # Canonical list defined in ./initrd-emergency-tools.nix (shared with bringup-zfs-disk-image.nix).
          extraBin = import ./initrd-emergency-tools.nix pkgs;
          services = {
            emergency.environment.SYSTEMD_SULOGIN_FORCE = "1";
            rescue.environment.SYSTEMD_SULOGIN_FORCE = "1";
            # Reduce initrd dependency-noise from kbd tooling (setfont/loadkeys)
            # in headless/serial bringup flows.
            "systemd-vconsole-setup".enable = lib.mkForce false;
          };
          contents."/etc/systemd/journald.conf".text = ''
            [Journal]
            ForwardToConsole=yes
            MaxLevelConsole=debug
          '';
          settings.Manager = systemdManagerShowStatusNo;
        }
        // (lib.optionalAttrs (bringupMode && rootFsType != "zfs") {
          # initrd repart: grow the root partition on /dev/vda for btrfs/ext4 bringup.
          # Not applicable for ZFS — the boot disk is EFI-only; ZFS pools handle their own layout.
          repart = {
            enable = false;
            device = "/dev/vda";
            empty = "allow";
          };
        });
      };

      # Keep /tmp volatile (tmpfs) and /var/tmp persistent, matching modern
      # systemd-oriented layout guidance for mutable temporary data.
      tmp.useTmpfs = lib.mkDefault true;

      postBootCommands = ''
        chmod 755 /boot || true
        chmod 600 /boot/loader/.#bootctlrandom-seed* 2>/dev/null || true
        if [ ! -e /run/current-system ] && [ -e /run/booted-system ]; then
          ln -s /run/booted-system /run/current-system
        fi
      '';
    };

    system = {
      stateVersion = "25.11"; # Update this when upgrading NixOS

      # Keep switch-to-configuration available in bootstrap images as well.
      # Disk-image bringup/activation paths may invoke:
      #   /nix/var/nix/profiles/system/bin/switch-to-configuration
      # and disabling system.switch causes hard boot failure (PID1 exit 127).
      switch.enable = lib.mkDefault true;

      # NixOS asserts that non-empty system.nssModules requires nscd.
      # While troubleshooting bootstrap console recovery with nscd disabled,
      # clear NSS module loading only for bootstrap mode.
      nssModules = lib.mkIf bringupMode (lib.mkForce [ ]);
    };

    fileSystems = lib.mkIf (!config.disko.enableConfig) {
      "/" = {
        device = "/dev/disk/by-label/nixos";
        autoResize = true;
        fsType = mkBringupOverride rootFsType;
        options = mkBringupOverride rootFsMountOptions;
      };
    };

    limaHost.isGuest = true;

    networking = {
      hostId = "deadbeef";
      # Canonical policy: firewall disabled on NixOS lab hosts.
      firewall.enable = lib.mkForce false;
    }
    // (lib.optionalAttrs runtimeMode {
      mammoth-skate.enable = lib.mkDefault runtimeMode;
    });

    environment = {
      systemPackages = [
        pkgs.binutils
        pkgs.disko
        pkgs.plymouth
        pkgs.btrfs-progs
      ]
      ++ (lib.optionals runtimeMode runtimeExtraSystemPackages);

      # Ensure security wrappers are in PATH for all processes
      variables = {
        PATH = lib.mkBefore [ "/run/wrappers/bin" ];
      };
    };

    services = {
      getty.autologinUser = rootUserName;

      # Bootstrap recovery path: avoid nsncd/nscd startup failures from cascading
      # into nss-* target dependency failures that break tty login/getty.
      nscd.enable = lib.mkForce runtimeMode;
      nscd.enableNsncd = lib.mkForce runtimeMode;

      nxmaticCachixWatchStore.enable = lib.mkDefault runtimeMode;
      ntopng = {
        enable = lib.mkDefault runtimeMode;
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
      journald = {
        console = lib.mkForce journaldConsoleDevice;
        extraConfig = ''
          # Bootstrap mode: mirror journald to serial console.
          ForwardToConsole=yes
          MaxLevelConsole=${journaldConsoleLevel}
        '';
      };
    }
    // (lib.optionalAttrs
      (runtimeMode && clusterNetwork != null && options ? services && options.services ? dbusTcpSystemBus)
      {
        # Expose system D-Bus over vmnet gateway for lab-only remote control/testing.
        dbusTcpSystemBus = {
          enable = true;
          bindAddress = clusterNetwork.gateway;
          port = 12434;
          openFirewall = true;
          insecureAllowAnonymous = true;
        };
      }
    );

    security.sudo = {
      enable = true;
      wheelNeedsPassword = false;
    };

    boot.growPartition = lib.mkIf bringupMode (lib.mkForce false);

    systemd = {
      settings.Manager = systemdManagerShowStatusNo;
      services = {
        # Rescue/emergency shell policy (@codebase): enforce sulogin behavior
        # via the same variable used by systemd service drop-ins.
        emergency.environment.SYSTEMD_SULOGIN_FORCE = "1";
        rescue.environment.SYSTEMD_SULOGIN_FORCE = "1";
      };
      # Grow the root partition (btrfs/ext4 bringup only).
      # For ZFS bringup the boot disk is EFI-only — no root partition exists on it.
      # ZFS pool expansion is handled by zpool:expand() in zpool-init.sh instead.
      repart.partitions = lib.mkIf (bringupMode && rootFsType != "zfs") {
        "50-nixos-root" = {
          Type = "root";
          Label = "nixos";
          GrowFileSystem = true;
        };
      };
    };

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
      extraGroups = nixosUserExtraGroups;
      uid = lib.mkIf (nixosUserUid != null) nixosUserUid;
    };
    users.groups.${cfgUserName} = if nixosUserGid != null then { gid = nixosUserGid; } else { };

    # builder user: accepts linux-builder key from all Darwin profiles for remote builds.
    # The public keys are baked in at build time from keys.yaml (not SOPS-encrypted).
    users.users.builder = lib.mkIf runtimeMode {
      isNormalUser = true;
      group = "builder";
      extraGroups = [
        "wheel"
        "nixbld"
      ];
      description = "Nix remote builder";
      openssh.authorizedKeys.keys = lib.filter (k: k != "") [
        (
          if
            builderKeys ? profiles
            && builderKeys.profiles ? committed
            && builderKeys.profiles.committed ? linux-builder
            && builderKeys.profiles.committed.linux-builder ? public
          then
            "ssh-ed25519 ${builderKeys.profiles.committed.linux-builder.public} committed-linux-builder"
          else
            ""
        )
        (
          if
            builderKeys ? profiles
            && builderKeys.profiles ? work
            && builderKeys.profiles.work ? linux-builder
            && builderKeys.profiles.work.linux-builder ? public
          then
            "ssh-ed25519 ${builderKeys.profiles.work.linux-builder.public} work-linux-builder"
          else
            ""
        )
      ];
    };
    users.groups.builder = lib.mkIf runtimeMode { };

    # root: also accepts linux-builder key for builds that require root-level operations.
    users.users.root.openssh.authorizedKeys.keys = lib.mkIf runtimeMode (
      lib.filter (k: k != "") [
        (
          if
            builderKeys ? profiles
            && builderKeys.profiles ? committed
            && builderKeys.profiles.committed ? linux-builder
            && builderKeys.profiles.committed.linux-builder ? public
          then
            "ssh-ed25519 ${builderKeys.profiles.committed.linux-builder.public} committed-linux-builder"
          else
            ""
        )
        (
          if
            builderKeys ? profiles
            && builderKeys.profiles ? work
            && builderKeys.profiles.work ? linux-builder
            && builderKeys.profiles.work.linux-builder ? public
          then
            "ssh-ed25519 ${builderKeys.profiles.work.linux-builder.public} work-linux-builder"
          else
            ""
        )
      ]
    );

  };

}
