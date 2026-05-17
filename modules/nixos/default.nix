{
  config,
  pkgs,
  lib,
  options,
  ndh,
  self,
  ...
}:

let
  # Boot/runtime kernel capabilities shared by stage1+stage2.
  kernelModules = [
    "nfs"
    "ext4"
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
    "overlay"
    "iso9660"
    "nfs"
    "nfs4"
  ];

  # Profile/user identity normalization for NixOS constraints.
  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;
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

  # Forensic/recovery tools for the initrd emergency shell.
  # Emergency tools for bringup VM shell (outside initrd).
  # The initrd emergency tools are configured via ./initrd-emergency.nix.
  initrdEmergencyTools = import ./initrd-emergency-tools.nix pkgs;

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
  initrdRescueAuthorizedKeys = lib.unique (
    lib.filter (key: key != "") (
      config.ndh.keysYaml.authorizedLinesFor [ "linux-builder" ]
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
  bootstrapRequiredImports = [
    "${self}/modules/.common.d"
    ./etc-backup.nix
    ./lima-network-interfaces.nix
    ./disko.nix
    ./systemd
    ./zfs.nix
    ./zfs-recovery-chroot.nix
    ./sops.nix
    ./dbus-tcp.nix
    ./vlan.nix
    ./tailscale.nix
    ./bringup-xchg-mount.nix
    ./cache-trust.nix
    ./nix-store-identity.nix
    ./bringup-runtime.nix
  ];

  runtimeOnlyImports = [
    # ./nixos-reduction.nix
    ./networking-mammoth-skate.nix
    ./cachix-watch-store.nix
    ./container-host.nix
    ./headscale.nix
    ./headscale-daemon.nix
    ./headscale-client-kind.nix
    ./nix-ld.nix
    ./resolved-lan.nix
    ./avahi.nix
    ./code-server.nix
    ./nfs-autofs.nix
    ./incus.nix
    ./podman.nix
    ./bringup-observe.nix
    ./etc-nixos-flake.nix
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
  imports = [
    ./initrd-emergency.nix
    ./console-serial.nix
    ./nix-settings.nix
    ./users.nix
    ./boot-loader.nix
  ]
  ++ bootstrapRequiredImports
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

    # Enable ZFS recovery chroot script
    zfsRecovery.enable = lib.mkDefault true;

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

    # Nix daemon configuration (nix.settings, nix.extraOptions) in ./nix-settings.nix

    # Boot configuration
    boot = {

      # Use an immutable store path for PID1 handoff in stage-2.
      # This avoids early-boot dependency on /run/current-system being present.
      systemdExecutable = "${config.systemd.package}/lib/systemd/systemd";

      inherit kernelModules supportedFilesystems;

      # Boot loader configuration (systemd-boot, EFI, timeout, grub) via ./boot-loader.nix

      kernelParams = lib.mkMerge [
        ([
          # Kernel cmdline journald routing:
          # - rd.systemd.* applies in initrd (early boot stage before switch_root)
          # - systemd.* applies in stage-2 (real root userspace)
          # Keep both for consistent serial visibility across bootstrap.
          "rd.systemd.journald.forward_to_console=1"
          # "rd.systemd.journald.console=/dev/${virtualSerialConsole}"
          "systemd.journald.forward_to_console=1"
          # "systemd.journald.console=/dev/${virtualSerialConsole}"
          # Console kernel params (console=tty0 console=hvc0) configured via ./console-serial.nix
        ])
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
          network.enable = lib.mkDefault bringupMode;
          # Emergency tools, emergencyAccess, and root discovery mode configured
          # via ./initrd-emergency.nix imported above.
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

    # Man pages are enabled; doc/info/nixos remain off to keep closure small.
    # nerd-nixos is headless — doc/info add no value; nixos options docs are
    # generated per-rebuild and slow bringup significantly.
    documentation = {
      enable = true;
      man.enable = true;
      doc.enable = false;
      info.enable = false;
      nixos.enable = false;
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
      # Per-host ZFS hostId derived from the bare host name (not the
      # `<host>-nixos` composite networking.hostName).  The minimal
      # bringup image uses the same formula at
      # modules/nixos/outputs.nix (minimalHostId) — both must agree,
      # otherwise zfs-import-<pool>.service refuses to import a pool
      # that was formatted under the other configuration with
      # "cannot import '<pool>': pool was previously in use from
      # another system".
      hostId =
        let
          hash = builtins.hashString "sha256" hostProfile.hostName;
        in
        builtins.substring 0 8 hash;
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
        pkgs.btrfs-progs
      ]
      ++ (lib.optionals runtimeMode runtimeExtraSystemPackages);

      # Ensure security wrappers are in PATH for all processes
      variables = {
        PATH = lib.mkBefore [ "/run/wrappers/bin" ];
      };
    };

    services = {
      # getty.autologinUser configured via ./console-serial.nix

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

    # User configuration (users.users.*, users.groups.*) in ./users.nix

  };

}
