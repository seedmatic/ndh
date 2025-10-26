# Lima configuration generator (@codebase)
# Generates lima.yaml with profile-aware user configuration

{ config, pkgs, lib, ... }:

let
  inherit (lib) mkOption types;

  profileUser = config.profile.user.name;
  profileHome = config.profile.user.home;
  profileHost = config.profile.host;
  profileHomeSymlinks = config.profile.homeSymlinks or [];
  
  # Derive effective hostname (use alias if set, otherwise hostName)
  effectiveHostName = if (profileHost ? hostAlias && profileHost.hostAlias != null && profileHost.hostAlias != "")
    then profileHost.hostAlias
    else profileHost.hostName;
  
  # Generate unique host byte from hostname hash (matches existing Lima VM)
  # Takes first byte of SHA256 hash of hostname
  hostByteHex = let
    hash = builtins.hashString "sha256" effectiveHostName;
    # Take first 2 hex chars from hash - already in valid range 00-ff
  in lib.strings.toLower (builtins.substring 0 2 hash);

  cfg = config.lima.configGenerator;

  mountType = if vmType == "qemu" then "9p" else "virtiofs";
  vmType = cfg.vmType;

  # Cluster mapping (@codebase)
  # We derive a deterministic clusterId from effectiveHostName so each host
  # gets a stable slice of the 10.80.0.0/18 supernet. Current documented layout:
  #   Cluster 1 (bioskop) -> 10.80.8.0/21
  #   Cluster 2 (alcide)  -> 10.80.16.0/21
  # We keep Lima's vmwan0 to a /24 slice carved from the cluster /21 for NAT.
  # NOTE: bioskop currently runs with 10.80.16.0/24 (mismatch). Enabling the
  # feature flag below will migrate bioskop to its intended 10.80.8.0/24 slice.
  hostClusterMap = {
    bioskop = 1;
    alcide = 2;
  };
  # Enforce mapping: explicit error if host not in hostClusterMap (@codebase)
  clusterId = let hn = effectiveHostName; in
    if builtins.hasAttr hn hostClusterMap then hostClusterMap.${hn}
    else builtins.throw "lima-config.nix: host '${hn}' missing in hostClusterMap; add an entry to define deterministic cluster subnet.";
  clusterBaseOctet = clusterId * 8; # 10.80.<octet>.0
  clusterBaseCidr = "10.80.${toString clusterBaseOctet}.0/21";
  # Lima vmwan0 deterministic addressing
  # We adopt the full cluster /21 netmask for the vmnet managed network (255.255.248.0)
  # while initially constraining DHCP leases to the first /24 slice for stability.
  limaWanSubnet = "10.80.${toString clusterBaseOctet}.0/21"; # documentation hint only; vmnet infers via gateway+netmask
  limaWanGateway = "10.80.${toString clusterBaseOctet}.1";    # first host IP of first /24
  limaWanDhcpEnd = "10.80.${toString clusterBaseOctet}.224";  # restrict DHCP to first /24; expand later by overwrite

  # Feature flag to activate socket_vmnet custom subnet instead of Lima default
  enableClusterSubnet = cfg.enableClusterSubnet or false;

  # Name for deterministic cluster network (managed via networks.yaml) (@codebase)
  clusterNetworkName = "cluster${toString clusterId}";
  limaNetworksOpts = config.lima.networks or {};

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
      { name = "nerd-nixos-tank1"; format = false; label = "zpool=tank"; }
      { name = "nerd-nixos-tank2"; format = false; label = "zpool=tank"; }
      { name = "nerd-nixos-tank3"; format = false; label = "zpool=tank"; }
      { name = "nerd-nixos-recover"; format = false; label = "zpool=recover"; }
    ];

    hostResolver = {
      enabled = true;
      ipv6 = true;
      hosts = {
        "guest.lima.internal" = "127.1.1.1";
        "host.containers.internal" = "192.168.5.15";
      };
    };

    images = [
      {
        location = "file:///Users/nxmatic/Gits/nxmatic/nix-darwin-home/result/nixos.img";
        arch = "aarch64";
      }
    ];

    mounts = [
      { location = "~"; writable = true; }
      { location = "/Volumes"; writable = true; }
      { location = "/tmp/lima"; writable = true; }
    ];

    mountType = mountType;

    ssh = {
      forwardAgent = true;
    };

    env = {
      PATH = "/run/wrappers/bin:/run/current-system/sw/bin";
    };

    containerd = {
      system = false;
      user = false;
    };

    provision = [
      {
        mode = "system";
        script = ''
          #!/bin/bash
          set -eux -o pipefail

          : "Create early symlinks for critical binaries including sudo"
          mkdir -p /bin
          ln -sf /run/current-system/sw/bin/bash /bin/bash || true

          : "Set PATH in ssh daemon environment - for non-interactive SSH commands"
          mkdir -p /etc/ssh/sshd_config.d
          cat > /etc/ssh/sshd_config.d/lima-path.conf << 'EOF'
          SetEnv PATH="/run/wrappers/bin:/run/current-system/sw/bin"
          EOF

          : "Ensure main sshd_config includes drop-in directory and permits user environment"
          if [ -f /etc/ssh/sshd_config ]; then
            if ! grep -qE '^\s*Include\s+sshd_config.d/\*' /etc/ssh/sshd_config && \
               ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d/\*' /etc/ssh/sshd_config; then
              printf '\nInclude /etc/ssh/sshd_config.d/*\n' >> /etc/ssh/sshd_config
            fi
            if ! grep -qE '^\s*PermitUserEnvironment\s+yes' /etc/ssh/sshd_config; then
              printf '\nPermitUserEnvironment yes\n' >> /etc/ssh/sshd_config
            fi
          else
            printf 'Include /etc/ssh/sshd_config.d/*\nPermitUserEnvironment yes\n' > /etc/ssh/sshd_config
          fi

          : "Install profile PATH exports for non-interactive sessions"
          install -d -m 755 /etc/profile.d
          cat > /etc/profile.d/noninteractive.sh << 'EOF'
          #!/bin/sh
          export PATH="/run/wrappers/bin:/run/current-system/sw/bin"
          EOF
          chmod 0644 /etc/profile.d/noninteractive.sh

          : "Ensure SSH environment directory exists for ${profileUser}"
          install -d -m 700 "/home/${profileUser}/.ssh"
          cat > "/home/${profileUser}/.ssh/environment" << 'EOF'
          PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin
          EOF
          chown -R "${profileUser}:${profileUser}" "/home/${profileUser}/.ssh"

          : "Reload sshd if available to pick up new configuration"
          systemctl try-reload-or-restart sshd.service 2>/dev/null || true

          : "Install Lima PATH helper script"
          mkdir -p /etc/profile.d
          cat > /etc/profile.d/lima-path.sh << 'EOF'
          export PATH="/run/wrappers/bin:/run/current-system/sw/bin:$PATH"
          EOF
          chmod +x /etc/profile.d/lima-path.sh

          : "Set systemd environment PATH for consistency"
          systemctl set-environment PATH="/run/wrappers/bin:/run/current-system/sw/bin"
        '';
      }
      {
        mode = "system";
        script = ''
          #!/bin/bash
          set -eux -o pipefail

          : "Ensure mount point for lima NixOS disk exists"
          mkdir -p /mnt/lima-nixos
          : "Mount lima NixOS disk"
          mount /dev/disk/by-label/nixos /mnt/lima-nixos
        '';
      }
    ];

    video = {
      display = "none";
    };

    # Network configuration: Custom socket_vmnet services for controlled subnet allocation
    # Using custom socket paths to enable hierarchical IP addressing (10.80.16.0/24)
    # MAC addressing scheme: OUI:LIMA:HOST:IF where IF indicates interface type
    networks = [
      {
        # Keep vzNAT for basic connectivity
        vzNAT = true;
        interface = "vznat0";
        macAddress = "10:66:6a:4c:${hostByteHex}:00";
      }
      {
        # Bridged LAN access (Headscale server, LoadBalancer IPs)
        lima = "bridged";
        interface = "vmlan0";
        macAddress = "10:66:6a:4c:${hostByteHex}:01";
      }
      {
        # Deterministic cluster shared network provided via networks.yaml
        # We reference a network name; its gateway/subnet are managed externally.
        lima = if enableClusterSubnet then clusterNetworkName else "shared";
        interface = "vmwan0";
        macAddress = "10:66:6a:4c:${hostByteHex}:02";
      }
    ];

  };

in {
  options.lima.configGenerator = {
    vmType = mkOption {
      type = types.enum [ "vz" "qemu" ];
      default = "vz";
      description = ''
        Select the virtualization backend for the generated Lima instance.
        "vz" uses Apple Virtualization.framework, "qemu" uses the QEMU driver.
      '';
    };
    enableClusterSubnet = mkOption {
      type = types.bool;
      default = true; # Deterministic subnet enabled by default (@codebase)
      description = ''
        Enable deterministic cluster subnet allocation for Lima vmwan0 using socket_vmnet.
        When true, vmwan0 is provisioned with a stable /24 carved from a per-host
        /21 slice of the 10.80.0.0/18 supernet derived from the hostname.
        Set to false to fall back to Lima's implicit shared 172.16.x subnet.
      '';
    };
   };
  # Internal, fully rendered configuration exposed for external tooling / scripts (@codebase)
  options.lima.computedConfig = mkOption {
    type = types.anything; # full limaConfig structure (@codebase)
    internal = true;       # hide from public option listings
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
    # Dedicated activation script using postActivation which is actually executed
    # Use mkAfter to run after other postActivation scripts (@codebase)
    system.activationScripts.postActivation.text = lib.mkAfter ''
      set -euo pipefail
      LOG="/var/log/darwin-lima-config.log"
      echo "[limaConfig] start $(date) host=${effectiveHostName} user=${profileUser}" >> "$LOG"

      : "Create Lima configuration directory in profile home"
      mkdir -p "${profileHome}/.lima/nerd-nixos"

      : "Generate lima.yaml with profile user configuration using yq"
      cat << 'EOF' | ${pkgs.yq-go}/bin/yq -P -p json -o yaml eval . - > "${profileHome}/.lima/nerd-nixos/lima.yaml"
${lib.generators.toJSON {} limaConfig}
EOF
      chmod 0600 "${profileHome}/.lima/nerd-nixos/lima.yaml"

      : "Ensure deterministic networks.yaml entry for ${clusterNetworkName} when feature flag enabled"
      ${lib.optionalString (enableClusterSubnet && limaNetworksOpts.enableManagedClusterNetwork) ''
      cfgdir="${profileHome}/.lima/_config"
      mkdir -p "$cfgdir"
      nwfile="$cfgdir/networks.yaml"
      desired_block="  ${clusterNetworkName}:\n    mode: shared\n    gateway: ${limaWanGateway}\n    dhcpEnd: ${limaWanDhcpEnd}\n    netmask: ${limaNetworksOpts.netmask}"
      if [ ! -f "$nwfile" ]; then
        echo "[limaConfig] creating new networks.yaml with ${clusterNetworkName}" >> "$LOG"
        cat > "$nwfile" <<'NETCFG'
paths:
  # socketVMNet path autodetect; omit for Lima to fill defaults
  varRun: /private/var/run/lima
group: everyone
networks:
NETCFG
        echo -e "$desired_block" >> "$nwfile"
      else
        if grep -q "^  ${clusterNetworkName}:" "$nwfile"; then
          # Extract existing block first 5 lines after header
          existing=$(grep -A4 "^  ${clusterNetworkName}:" "$nwfile" || true)
          if echo "$existing" | grep -q "gateway: ${limaWanGateway}" && \
             echo "$existing" | grep -q "dhcpEnd: ${limaWanDhcpEnd}" && \
             echo "$existing" | grep -q "netmask: ${limaNetworksOpts.netmask}"; then
            echo "[limaConfig] ${clusterNetworkName} block matches desired values" >> "$LOG"
          else
            ${lib.optionalString limaNetworksOpts.overwrite ''
            echo "[limaConfig] overwriting ${clusterNetworkName} block (values differ)" >> "$LOG"
            awk -v start="  ${clusterNetworkName}:" 'BEGIN{skip=0} {
              if($0==start){print; skip=4; next}
              if(skip>0){skip--; next}
              print
            }' "$nwfile" > "$nwfile.tmp" && mv "$nwfile.tmp" "$nwfile"
            ''}
            ${lib.optionalString (!limaNetworksOpts.overwrite) ''
            echo "[limaConfig][WARN] ${clusterNetworkName} differs; overwrite disabled" >> "$LOG"
            ''}
          fi
        else
          echo "[limaConfig] appending ${clusterNetworkName} to existing networks.yaml" >> "$LOG"
          echo -e "$desired_block" >> "$nwfile"
        fi
      fi
      ''}

      : "Create symlinks for alternate profile homes (homeSymlinks)"
      ${lib.optionalString (profileHomeSymlinks != []) ''
      # shellcheck disable=SC2043
      for altUser in ${lib.concatStringsSep " " (map (u: ''"${u}"'') profileHomeSymlinks)}; do
        altHome="/Users/$altUser"
        if [ "$altHome" != "${profileHome}" ]; then
          mkdir -p "$altHome/.lima/nerd-nixos"
          if [ -f "${profileHome}/.lima/nerd-nixos/lima.yaml" ]; then
            ln -sf "${profileHome}/.lima/nerd-nixos/lima.yaml" "$altHome/.lima/nerd-nixos/lima.yaml" || true
          fi
        fi
      done
      ''}

      : "Verify output file"
      if [ -f "${profileHome}/.lima/nerd-nixos/lima.yaml" ]; then
        echo "[limaConfig] generated size=$(wc -c < "${profileHome}/.lima/nerd-nixos/lima.yaml")" >> "$LOG"
        grep -E 'gateway|clusterId' "${profileHome}/.lima/nerd-nixos/lima.yaml" >> "$LOG" || true
        touch /var/db/lima-config-generated
      else
        echo "[limaConfig][ERROR] lima.yaml missing after generation attempt" >> "$LOG"
      fi
      echo "[limaConfig] end $(date)" >> "$LOG"
    '';
    # Expose full rendered configuration for external tooling (@codebase)
    lima.computedConfig = limaConfig;
  };
}
