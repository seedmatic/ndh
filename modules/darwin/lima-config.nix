# Lima configuration generator (@codebase)
# Generates lima.yaml with profile-aware user configuration

{ config, pkgs, lib, ... }:

let
  inherit (lib) mkOption types;

  profileUser = config.profile.user.name;
  profileHome = config.profile.user.home;

  cfg = config.lima.generator;

  effectiveVmType = cfg.vmType;
  defaultMac = cfg.macAddress;
  effectiveMountType =
    if cfg.mountType != null then cfg.mountType
    else if effectiveVmType == "vz" then "virtiofs" else "9p";

  defaultNetworks =
    if effectiveVmType == "vz" then [
      {
        vzNAT = true;
        macAddress = defaultMac;
      }
    ] else [];
#    ] else [
#      {
#        lima = "socket_vmnet";
#        macAddress = defaultMac;
#        socketVMNet = {
#          sharedNetwork = false;
#          dhcp = true;
#        };
#      }
#    ];

  effectiveNetworks =
    if cfg.networks != null then cfg.networks else defaultNetworks;

  limaConfig = {
    cpus = 8;
    disk = "24GiB";
    memory = "24GiB";
    plain = false;
    vmType = effectiveVmType;

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

    mountType = effectiveMountType;

    networks = effectiveNetworks;

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

          # Create early symlinks for critical binaries including sudo
          mkdir -p /bin
          ln -sf /run/current-system/sw/bin/bash /bin/bash || true

          # Set PATH in ssh daemon environment - for non-interactive SSH commands
          mkdir -p /etc/ssh/sshd_config.d
          cat > /etc/ssh/sshd_config.d/lima-path.conf << 'EOF'
          SetEnv PATH="/run/wrappers/bin:/run/current-system/sw/bin"
          EOF

          # Ensure main sshd_config includes the drop-in directory very early
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

          install -d -m 755 /etc/profile.d
          cat > /etc/profile.d/noninteractive.sh << 'EOF'
          #!/bin/sh
          export PATH="/run/wrappers/bin:/run/current-system/sw/bin"
          EOF
          chmod 0644 /etc/profile.d/noninteractive.sh

          install -d -m 700 "/home/${profileUser}/.ssh"
          cat > "/home/${profileUser}/.ssh/environment" << 'EOF'
          PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin
          EOF
          chown -R "${profileUser}:${profileUser}" "/home/${profileUser}/.ssh"

          systemctl try-reload-or-restart sshd.service 2>/dev/null || true

          mkdir -p /etc/profile.d
          cat > /etc/profile.d/lima-path.sh << 'EOF'
          export PATH="/run/wrappers/bin:/run/current-system/sw/bin:$PATH"
          EOF
          chmod +x /etc/profile.d/lima-path.sh

          systemctl set-environment PATH="/run/wrappers/bin:/run/current-system/sw/bin"
        '';
      }
      {
        mode = "system";
        script = ''
          #!/bin/bash
          set -eux -o pipefail

          mkdir -p /mnt/lima-nixos
          mount /dev/disk/by-label/nixos /mnt/lima-nixos
        '';
      }
    ];

    video = {
      display = "none";
    };


  };

in {
  options.lima.generator = {
    vmType = mkOption {
      type = types.enum [ "vz" "qemu" ];
      default = "vz";
      description = ''
        Select the virtualization backend for the generated Lima instance.
        "vz" uses Apple Virtualization.framework, "qemu" uses the QEMU driver.
      '';
    };

    mountType = mkOption {
      type = types.nullOr (types.enum [ "virtiofs" "9p" ]);
      default = null;
      description = ''
        Override the mount type used for Lima shared directories.
        When unset, virtiofs is used for "vz" and 9p for "qemu".
      '';
    };

    macAddress = mkOption {
      type = types.str;
      default = "52:55:55:4d:28:2a";
      description = "MAC address assigned to the first Lima NIC.";
    };

    networks = mkOption {
      type = types.nullOr (types.listOf (types.attrsOf types.anything));
      default = null;
      description = ''
        Custom network definitions for the Lima instance. When unset a sensible
        default is chosen based on the selected vmType (vzNAT for "vz", socket_vmnet for "qemu").
      '';
    };
  };

  config = {
    system.activationScripts.postActivation.text = ''
      : Create Lima configuration directory in profile home
      mkdir -p "${profileHome}/.lima/nerd-nixos"

      : Generate lima.yaml with profile user configuration using yq
      cat << 'EOF' | ${pkgs.yq-go}/bin/yq -P -p json -o yaml eval . - > "${profileHome}/.lima/nerd-nixos/lima.yaml"
      ${lib.generators.toJSON {} limaConfig}
      EOF
    '';
  };
}
