# Lima configuration generator (@codebase)
# Generates lima.yaml with profile-aware user configuration

{
  config,
  pkgs,
  lib,
  catalog,
  inventory,
  ndh,
  ...
}:

let
  inherit (lib) mkOption types;
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";

  dollar = "$"; # escape for shell scripts

  profileUser = config.profile.user.name;
  vmGuestUser =
    if catalog ? users && catalog.users ? committed && catalog.users.committed ? name then
      catalog.users.committed.name
    else
      builtins.throw "lima-config.nix: catalog.users.committed.name is required for canonical NixOS VM guest user";
  committedHostHome =
    if catalog ? users && catalog.users ? committed && catalog.users.committed ? home then
      catalog.users.committed.home
    else
      "/Users/${vmGuestUser}";
  profileHome = config.profile.user.home;
  profileHost = config.profile.host;
  sshPaths = config.sshPaths;
  loggerScript = config.nixBashLogger.script;

  # Derive effective hostname (use alias if set, otherwise hostName)
  effectiveHostName =
    if (profileHost ? hostAlias && profileHost.hostAlias != null && profileHost.hostAlias != "") then
      profileHost.hostAlias
    else
      profileHost.hostName;

  profileName = config.profile.name;
  hostInventoryEntries =
    lib.attrByPath
      [
        "hosts"
        effectiveHostName
      ]
      [ ]
      inventory;
  hostIsVmOnly =
    hostInventoryEntries != [ ]
    && lib.all (entry: (entry ? form) && entry.form == "vm") hostInventoryEntries;
  limaRuntimeSupported = !hostIsVmOnly;
  # Generate unique host byte from hostname hash (matches existing Lima VM)
  # Takes first byte of SHA256 hash of hostname
  hostByteHex =
    let
      hash = builtins.hashString "sha256" effectiveHostName;
      # Take first 2 hex chars from hash - already in valid range 00-ff
    in
    lib.strings.toLower (builtins.substring 0 2 hash);

  cfg = config.lima.configGenerator;

  # Canonical source-of-truth network values from rke2lab netplan catalog (@codebase)
  rke2labNetplan = catalog.netplan.rke2lab;

  # Canonical disk → ZFS pool membership (shared with bringup config)
  limaVmName = "nerd-nixos";
  zfsPoolDiskMap = import ../nixos/zfs-pool-disk-map.nix;
  limaAdditionalDisks = map (entry: {
    name = "${limaVmName}-${entry.disk}";
    format = false;
    label = "zpool=${entry.pool}";
  }) zfsPoolDiskMap;

  # Stable image staging paths
  imageManifestPath = if cfg.imageManifestPath == null then "" else toString cfg.imageManifestPath;
  imageStorePath = if cfg.imageStorePath == null then "" else toString cfg.imageStorePath;
  imageSourcePath = cfg.imageSourcePath;
  imageTargetPath = cfg.imageTargetPath;
  imageFlakeAttr = cfg.imageFlakeAttr;

  mountType = if vmType == "qemu" then "9p" else "virtiofs";
  vmType = cfg.vmType;
  networks =
    if vmType == "qemu" then
      [
        {
          # Dedicated socket_vmnet shared network for host/guest services (e.g., NFS).
          # Keep this before bridged so hostagent SSH prefers a host-routable endpoint.
          lima = "shared";
          interface = "vmhost0";
          macAddress = "10:66:6a:4c:${hostByteHex}:02";
          metric = 50;
        }
        {
          # Bridged LAN access for VM direct connectivity.
          # On bioskop: bridges to bond0 (en0+en8 aggregate)
          # On other hosts: bridges to en0 (single interface)
          lima = "bridged";
          interface = "vmlan0";
          macAddress = "10:66:6a:4c:${hostByteHex}:01";
          metric = 100;
        }
      ]
    else
      [
        {
          # Keep vzNAT for basic connectivity
          vzNAT = true;
          interface = "vznat0";
          macAddress = "10:66:6a:4c:${hostByteHex}:00";
          metric = 200;
        }
        {
          # Dedicated socket_vmnet shared network for host/guest services (e.g., NFS)
          # Keep this before bridged so hostagent SSH prefers a host-routable endpoint.
          lima = "shared";
          interface = "vmhost0";
          macAddress = "10:66:6a:4c:${hostByteHex}:02";
          metric = 50;
        }
        {
          # Bridged LAN access for VM direct connectivity
          # On bioskop: bridges to bond0 (en0+en8 aggregate)
          # On other hosts: bridges to en0 (single interface)
          # VM gets direct LAN access via this interface
          lima = "bridged";
          interface = "vmlan0";
          macAddress = "10:66:6a:4c:${hostByteHex}:01";
          metric = 100;
        }
      ];

  # Cluster mapping (@codebase)
  # Derive host -> cluster index from canonical rke2lab netplan catalog.
  #
  # Note: vmwan0 removed from Lima config. Incus containers now use:
  # - lan0: macvlan on vmlan0 (bridged to bond0/en0) for internet access
  # - wan0: Incus bridge network (10.80.x.0/21) for cluster-internal communication
  hostClusterMap = lib.mapAttrs (_: cluster: cluster.index) rke2labNetplan.clusters;
  # Enforce mapping: explicit error if host not in hostClusterMap (@codebase)
  clusterId =
    let
      hn = effectiveHostName;
    in
    if builtins.hasAttr hn hostClusterMap then
      hostClusterMap.${hn}
    else
      builtins.throw "lima-config.nix: host '${hn}' missing in hostClusterMap; add an entry to define deterministic cluster subnet.";

  # Name for deterministic cluster network (managed via networks.yaml) (@codebase)
  clusterNetworkName = "cluster${toString clusterId}";
  limaNetworksOpts = config.lima.networks or { };

  limaActivationScript = ndh.store.runCommand "lima-config-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./lima-config.d/activation.sh {
        nixBashTrampoline = nixBashTrampoline;
        effectiveHostName = effectiveHostName;
        profileUser = profileUser;
        profileHome = profileHome;
        limaConfigYaml = limaConfigYaml;
        limaRunScript = limaRunScript;
        imageManifestPath = imageManifestPath;
        imageStorePath = imageStorePath;
        imageSourcePath = imageSourcePath;
        imageTargetPath = imageTargetPath;
        imageFlakeAttr = imageFlakeAttr;
        nixosFlakePath = cfg.nixosFlakePath;
        hostPublicKeyPath = sshPaths.hostPublicKeyFile;
        hostPrivateKeyPath = sshPaths.privKeyFile;
      }
    } "$out"
    chmod +x "$out"
  '';

  limaRunScript = ndh.store.runCommand "lima-run.sh" { } ''
    cp ${
      pkgs.replaceVars ./lima-config.d/run.sh {
        nixBashTrampoline = nixBashTrampoline;
        effectiveHostName = effectiveHostName;
        nixosFlakePath = cfg.nixosFlakePath;
        nixosHostAttr = cfg.nixosHostAttr;
        imageTargetPath = imageTargetPath;
      }
    } "$out"
    chmod +x "$out"
  '';

  limaMaterializerPackage = pkgs.writeShellScriptBin "nerd-nixos-lima-vm-materialize" ''
    set -euo pipefail

    gcroot_user="''${SUDO_USER:-$(id -un)}"
    materializer_out="$(cd "$(dirname "$0")/.." && pwd -P)"
    gcroot_dir="/nix/var/nix/gcroots/per-user/''${gcroot_user}"
    gcroot_link="''${gcroot_dir}/nerd-nixos-lima-vm-materialize"

    mkdir -p "''${gcroot_dir}"
    ${pkgs.nix}/bin/nix-store --realise --add-root "''${gcroot_link}" --indirect "''${materializer_out}" >/dev/null

    exec ${limaActivationScript} "$@"
  '';

  limaConfig = {
    cpus = 8;
    disk = "${toString cfg.diskSizeGiB}GiB";
    memory = "24GiB";
    plain = false;
    vmType = vmType;

    user = {
      name = vmGuestUser;
    };

    additionalDisks = limaAdditionalDisks;

    hostResolver = {
      enabled = true;
      ipv6 = true;
      hosts = {
        "guest.lima.internal" = "127.1.1.1";
        # Note: Incus containers access internet via lan0 macvlan (vmlan0 parent -> bond0/en0)
        # Cluster communication via wan0 (Incus bridge network 10.80.x.0/21)
      };
    };

    images = [
      {
        location = "file://${imageTargetPath}";
        arch = "aarch64";
      }
    ];

    mounts = [
      {
        # Explicit host home source; avoid '~' resolution against vm guest user name
        # (which can point to non-existent /Users/<committed-user> on the host).
        location = "${profileHome}";
        # Keep the same path layout as host inside the guest.
        mountPoint = "${profileHome}";
        writable = true;
      }
      {
        # Host-provided SOPS age key for first-boot bootstrap import (@codebase)
        # Keep read-only and import it into /etc/sops/age/keys.txt during activation.
        location = "${profileHome}/.config/sops/age";
        mountPoint = "/mnt/lima-cidata/.sops.d";
        writable = false;
      }
      {
        # Export NDH top-level flake checkout to guest runtime.
        # NOTE: Lima assigns virtiofs tags as mount{N}; do not rely on static tag names.
        # Consumers should use this stable mountpoint path instead.
        location = "${cfg.nixosFlakePath}";
        mountPoint = "/run/ndh/host-shares/ndh-toplevel";
        writable = false;
      }
      {
        location = "/tmp/lima";
        writable = true;
      }
    ];

    mountType = mountType;

    ssh = {
      forwardAgent = true;
    } // (lib.optionalAttrs (cfg.sshLocalPort != 0) {
      localPort = cfg.sshLocalPort;
    });

    env = {
      PATH = "/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin";
    };

    containerd = {
      system = false;
      user = false;
    };

    # Provisioning scripts are not executed in this cloud-init setup
    #
    #   still have to state about the remaining scripts to be
    #   defined as systemd one-shot services in lima-cloud-init.nix
    #
    # provision = [
    #   {
    #     mode = "system";
    #     script = ''
    #       #!/bin/bash
    #       set -eux -o pipefail

    #       : "Create early symlinks for critical binaries including sudo"
    #       mkdir -p /bin
    #       ln -sf /run/current-system/sw/bin/bash /bin/bash || true

    #       : "Set PATH in ssh daemon environment - for non-interactive SSH commands"
    #       mkdir -p /etc/ssh/sshd_config.d
    #       cat > /etc/ssh/sshd_config.d/lima-path.conf << 'EOF'
    #       SetEnv PATH="/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
    #       EOF

    #       : "Ensure main sshd_config includes drop-in directory and permits user environment"
    #       if [ -f /etc/ssh/sshd_config ]; then
    #         if ! grep -qE '^\s*Include\s+sshd_config.d/\*' /etc/ssh/sshd_config && \
    #            ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d/\*' /etc/ssh/sshd_config; then
    #           printf '\nInclude /etc/ssh/sshd_config.d/*\n' >> /etc/ssh/sshd_config
    #         fi
    #         if ! grep -qE '^\s*PermitUserEnvironment\s+yes' /etc/ssh/sshd_config; then
    #           printf '\nPermitUserEnvironment yes\n' >> /etc/ssh/sshd_config
    #         fi
    #       else
    #         printf 'Include /etc/ssh/sshd_config.d/*\nPermitUserEnvironment yes\n' > /etc/ssh/sshd_config
    #       fi
    #     '';
    #   }
    #   {
    #     mode = "system";
    #     script = ''
    #       #!/bin/bash
    #       set -eux -o pipefail

    #       : "Install profile PATH exports for non-interactive sessions"
    #       install -d -m 755 /etc/profile.d
    #       cat > /etc/profile.d/noninteractive.sh << 'EOF'
    #       #!/bin/sh
    #       export PATH="/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
    #       EOF
    #       chmod 0644 /etc/profile.d/noninteractive.sh

    #       : "Install Lima PATH helper script"
    #       mkdir -p /etc/profile.d
    #       cat > /etc/profile.d/lima-path.sh << 'EOF'
    #       export PATH="/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH"
    #       EOF
    #       chmod +x /etc/profile.d/lima-path.sh

    #       : "Set systemd environment PATH for consistency"
    #       systemctl set-environment PATH="/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
    #     '';
    #   }
    #   {
    #     mode = "system";
    #     script = ''
    #       #!/bin/bash
    #       set -eux -o pipefail

    #       : "Ensure SSH environment directory exists for ${profileUser}"
    #       install -d -m 700 "/home/${profileUser}/.ssh"
    #       cat > "/home/${profileUser}/.ssh/environment" << 'EOF'
    #       PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin
    #       EOF
    #       chown -R "${profileUser}:${profileUser}" "/home/${profileUser}/.ssh"

    #       : "Reload sshd if available to pick up new configuration"
    #       systemctl try-reload-or-restart sshd.service 2>/dev/null || true
    #     '';
    #   }
    #   {
    #     mode = "system";
    #     script = ''
    #       #!/bin/bash
    #       set -eux -o pipefail

    #       : "Ensure mount point for lima NixOS disk exists"
    #       mkdir -p /mnt/lima-nixos
    #       : "Mount lima NixOS disk"
    #       mount /dev/disk/by-label/nixos /mnt/lima-nixos
    #     '';
    #   }
    # ];

    video = {
      display = "none";
    };

    # Network configuration: Custom socket_vmnet services for controlled subnet allocation
    # MAC addressing scheme: OUI:LIMA:HOST:IF where IF indicates interface type
    #
    # Network architecture (November 2025):
    # - vzNAT: Basic Lima connectivity (not used by Incus containers)
    # - vmlan0: Bridged to bond0 (bioskop) or en0 (other hosts) - EXCLUSIVE internet path for containers
    #   Containers use macvlan devices attached to vmlan0 parent interface for LAN/internet access
    # Note: vmwan0 removed - containers now attach wan0 directly to Incus bridge network (wan/vmnet),
    #       not Lima socket_vmnet shared networks
    # Note: vzNAT creates bridge interfaces on macOS; network-bond-maintain removes their default routes
    networks = networks;

  };

  limaConfigJson = lib.generators.toJSON { } limaConfig;
  limaConfigYaml = (pkgs.formats.yaml { }).generate "lima.yaml" limaConfig;

in
{
  options.lima.configGenerator = {
    imageManifestPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional path to a disk-image manifest output containing `manifest.yaml`.
        When provided, activation resolves the image using manifest metadata (`imagePath`) first.
      '';
    };

    imageStorePath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Store-pinned path to a prebuilt `nixos.img` used as first-priority source.
        This is the preferred mode for hosts like vz-host that should not resolve
        images from a local flake checkout or remote Git source.
      '';
    };

    vmType = mkOption {
      type = types.enum [
        "vz"
        "qemu"
      ];
      default = "vz";
      description = ''
        Select the virtualization backend for the generated Lima instance.
        "vz" uses Apple Virtualization.framework, "qemu" uses the QEMU driver.
      '';
    };

    enableIncus = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable Incus container runtime in the Lima VM.
        When true, the VM will include Incus for running containers.
      '';
    };

    imageSourcePath = mkOption {
      type = types.str;
      default = "";
      description = ''
        Optional direct source path for the NixOS disk image.
        Canonical behavior resolves from flake output first; this path is only used as a fallback.
      '';
    };

    imageTargetPath = mkOption {
      type = types.str;
      default = "/nix/var/nix/gcroots/per-user/${profileUser}/lima-nixos.img";
      description = ''
        Stable user gcroot symlink path for the NixOS disk image that Lima references.
        Activation registers this path via `nix-store --add-root --indirect` to prevent GC.
      '';
    };

    imageFlakeAttr = mkOption {
      type = types.str;
      default = "nixosDiskImages.${effectiveHostName}.bringup.zfsSystemd";
      description = ''
        Flake output attribute for the NixOS ZFS bringup disk image.
        The root flake exposes disk images under `nixosDiskImages.<host>.bringup.*`.
        Used as a reference label in activation.sh; the actual image path comes from imageManifestPath.
      '';
    };

    diskSizeGiB = mkOption {
      type = types.int;
      default = 24;
      description = ''
        Root disk size in GiB exposed by Lima to the guest for the primary VM disk.
        Keep this aligned with the selected NixOS disk-image profile size to avoid
        host/guest disk-size drift.
      '';
    };

    nixosFlakePath = mkOption {
      type = types.str;
      default = "/var/lib/git/nxmatic/nix-darwin-home";
      description = ''
        Host-side flake path used by ~/.lima/run.sh for remote NixOS activation.
      '';
    };

    nixosHostAttr = mkOption {
      type = types.str;
      default = "${effectiveHostName}-nixos";
      description = ''
        NixOS flake attribute selected by ~/.lima/run.sh for remote activation.
      '';
    };

    enableActivationHook = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run Lima materialization during darwin activation (`postActivation`).
        Disable when you want manual host-scoped execution through `nerd-nixos-lima-vm-materialize` only.
      '';
    };

    installMaterializerPackage = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install the `nerd-nixos-lima-vm-materialize` helper package in system packages.
        Useful on selected VZ hosts where only ~/.lima materialization tooling is needed.
      '';
    };

    materializerPackage = mkOption {
      type = types.package;
      readOnly = true;
      default = limaMaterializerPackage;
      description = ''
        Store package exposing the `nerd-nixos-lima-vm-materialize` command for host-side
        ~/.lima materialization.
      '';
    };

    requireNetAutomount = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Require Darwin autofs `/net` wiring for Lima configuration.
        Keep disabled unless you intentionally depend on `/net`-based image paths.
      '';
    };

    sshLocalPort = mkOption {
      type = types.int;
      default = 0;
      description = ''
        Fixed SSH listen port on the host side for this Lima VM (0 = auto-assign by Lima).
        Set a non-zero value to use this VM as a stable Nix remote builder without relying
        on the dynamically generated Lima SSH config. The nix daemon will SSH to
        127.0.0.1:<sshLocalPort> as the builder user.
      '';
    };
  };
  # Internal, fully rendered configuration exposed for external tooling / scripts (@codebase)
  options.lima.computedConfig = mkOption {
    type = types.anything; # full limaConfig structure (@codebase)
    internal = true; # hide from public option listings
    description = ''
      Fully rendered Lima configuration derived from module inputs. Internal use only.
      Prefer querying this for downstream tooling instead of re-deriving structure.
      NOTE: Not readOnly to allow single assignment; no default to avoid multi-definition conflicts.
    '';
  };
  # Managed networks.yaml control options (@codebase)
  options.lima.networks = {
    enableManagedClusterNetwork = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Generate or update $HOME/.lima/_config/networks.yaml with a deterministic per-host
        cluster network entry (cluster<clusterId>). Disable if you need full manual control.
      '';
    };
    netmask = mkOption {
      type = types.str;
      default = "255.255.248.0"; # full /21 cluster slice (was /24 previously)
      description = ''
        Netmask for the managed cluster network. Default now exposes full /21 (255.255.248.0).
        To revert to the previous /24 behavior set 255.255.255.0; DHCP remains limited to first /24 by default.
      '';
    };
    overwrite = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When true, an existing cluster<id> block in networks.yaml that differs (gateway/dhcpEnd/netmask)
        will be replaced in-place. When false, mismatches are logged and left unchanged.
      '';
    };
  };
  config = {
    assertions = lib.optionals cfg.requireNetAutomount [
      {
        assertion =
          (lib.attrByPath [
            "services"
            "nfsDarwin"
            "enable"
          ] false config)
          && (lib.attrByPath [
            "services"
            "nfsDarwin"
            "autofs"
            "enable"
          ] false config)
          &&
            (lib.attrByPath [
              "services"
              "nfsDarwin"
              "autofs"
              "mountPoint"
            ] "" config) == "/net";
        message = ''
          lima.configGenerator requires Darwin autofs `/net` but current nfsDarwin settings do not provide it.
          Enable:
            services.nfsDarwin.enable = true;
            services.nfsDarwin.autofs.enable = true;
            services.nfsDarwin.autofs.mountPoint = "/net";
          Or explicitly set:
            lima.configGenerator.requireNetAutomount = false;
        '';
      }
    ];

    # Install Lima runtime tooling only on supported host forms.
    # Darwin VM hosts (nested environments) are excluded by policy.
    environment.systemPackages =
      lib.optionals limaRuntimeSupported [ pkgs.lima ]
      ++ lib.optionals (limaRuntimeSupported && cfg.installMaterializerPackage) [
        cfg.materializerPackage
      ];

    # Dedicated activation script using postActivation which is actually executed
    # Use mkAfter to run after other postActivation scripts (@codebase)
    system.activationScripts.postActivation.text =
      lib.mkIf (limaRuntimeSupported && cfg.enableActivationHook)
        (
          lib.mkAfter ''
            ${limaActivationScript}
          ''
        );
    # Expose full rendered configuration for external tooling (@codebase)
    lima.computedConfig = limaConfig;
  };
}
