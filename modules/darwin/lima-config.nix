# Lima configuration generator (@codebase)
# Generates lima.yaml with profile-aware user configuration

{
  config,
  pkgs,
  lib,
  catalog,
  ...
}:

let
  inherit (lib) mkOption types;

  dollar = "$"; # escape for shell scripts

  profileUser = config.profile.user.name;
  profileHome = config.profile.user.home;
  profileHost = config.profile.host;

  # Host-side Lima user key (managed by home-manager keys; activation will symlink)
  hostLimaUserPubPath = "${profileHome}/.lima/_config/user.pub";

  # Derive effective hostname (use alias if set, otherwise hostName)
  effectiveHostName =
    if (profileHost ? hostAlias && profileHost.hostAlias != null && profileHost.hostAlias != "") then
      profileHost.hostAlias
    else
      profileHost.hostName;

  profileName = config.profile.name;
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
  netplanCatalog = catalog.networks.rke2labNetplan;

  # Stable image staging paths
  imageSourcePath = cfg.imageSourcePath;
  imageTargetPath = cfg.imageTargetPath;

  mountType = if vmType == "qemu" then "9p" else "virtiofs";
  vmType = cfg.vmType;

  # Cluster mapping (@codebase)
  # Derive host -> cluster index from canonical rke2lab netplan catalog.
  #
  # Note: vmwan0 removed from Lima config. Incus containers now use:
  # - lan0: macvlan on vmlan0 (bridged to bond0/en0) for internet access
  # - wan0: Incus bridge network (10.80.x.0/21) for cluster-internal communication
  hostClusterMap = lib.mapAttrs (_: cluster: cluster.index) netplanCatalog.clusters;
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

  yqBin = "${pkgs.yq-go}/bin/yq";

  limaActivationScript = pkgs.runCommand "lima-config-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./lima-config.d/activation.sh {
        effectiveHostName = effectiveHostName;
        profileUser = profileUser;
        profileHome = profileHome;
        yqBin = yqBin;
        limaConfigJson = limaConfigJson;
        limaRunScript = limaRunScript;
        imageSourcePath = imageSourcePath;
        imageTargetPath = imageTargetPath;
        activationLogger = lib.attrByPath [
          "activation"
          "loggerScript"
        ] ../common/activation-logger.sh config;
      }
    } "$out"
    chmod +x "$out"
  '';

  limaRunScript = pkgs.runCommand "lima-run.sh" { } ''
    cp ${
      pkgs.replaceVars ./lima-config.d/run.sh {
        effectiveHostName = effectiveHostName;
        nixosFlakePath = cfg.nixosFlakePath;
        nixosHostAttr = cfg.nixosHostAttr;
      }
    } "$out"
    chmod +x "$out"
  '';

  limaConfig = {
    cpus = 8;
    disk = "24GiB";
    memory = "24GiB";
    plain = false;
    vmType = vmType;

    user = {
      name = profileUser;
    };

    additionalDisks = [
      {
        name = "nerd-nixos-tank1";
        format = false;
        label = "zpool=tank";
      }
      {
        name = "nerd-nixos-tank2";
        format = false;
        label = "zpool=tank";
      }
      {
        name = "nerd-nixos-tank3";
        format = false;
        label = "zpool=tank";
      }
      {
        name = "nerd-nixos-recover";
        format = false;
        label = "zpool=recover";
      }
    ];

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
        location = "~";
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
        location = "/var/lib/git";
        writable = true;
      }
      {
        location = "/tmp/lima";
        writable = true;
      }
    ];

    mountType = mountType;

    ssh = {
      forwardAgent = true;
    };

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
    networks = [
      {
        # Keep vzNAT for basic connectivity
        vzNAT = true;
        interface = "vznat0";
        macAddress = "10:66:6a:4c:${hostByteHex}:00";
      }
      {
        # Bridged LAN access for VM direct connectivity
        # On bioskop: bridges to bond0 (en0+en8 aggregate)
        # On other hosts: bridges to en0 (single interface)
        # VM gets direct LAN access via this interface
        lima = "bridged";
        interface = "vmlan0";
        macAddress = "10:66:6a:4c:${hostByteHex}:01";
      }
      {
        # Dedicated socket_vmnet shared network for host/guest services (e.g., NFS)
        lima = "shared";
        interface = "vmhost0";
        macAddress = "10:66:6a:4c:${hostByteHex}:02";
      }
    ];

  };

  limaConfigJson = lib.generators.toJSON { } limaConfig;

in
{
  options.lima.configGenerator = {
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
      default = "/net/${effectiveHostName}.local/private/var/lib/git/nxmatic/nix-darwin-home/hosts/${effectiveHostName}/nixos/nixos.img";
      description = ''
        Source path of the built NixOS disk image (typically an out-link in the repo).
      '';
    };

    imageTargetPath = mkOption {
      type = types.str;
      default = "/net/${effectiveHostName}.local/private/var/lib/git/nxmatic/nix-darwin-home/hosts/${effectiveHostName}/nixos-disk-image/nixos.img";
      description = ''
        Stable host path for the NixOS disk image that Lima references. If different from imageSourcePath,
        the activation script copies/reflinks the image; when equal, no copy is performed.
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
    # Add lima to system packages
    environment.systemPackages = [ pkgs.lima ];

    # Dedicated activation script using postActivation which is actually executed
    # Use mkAfter to run after other postActivation scripts (@codebase)
    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${limaActivationScript}
    '';
    # Expose full rendered configuration for external tooling (@codebase)
    lima.computedConfig = limaConfig;
  };
}
