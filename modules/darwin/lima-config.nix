# Lima configuration generator (@codebase)
# Generates lima.yaml with profile-aware user configuration

{ config, pkgs, lib, ... }:

let
  profileUser = config.profile.user.name;
  profileHome = config.profile.user.home;
  
  limaConfig = {
    cpus = 8;
    memory = "24GiB";
    disk = "24GiB";
    vmType = "vz";
    plain = false;
    
    # User configuration - uses profile user
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
      ipv6 = true;  # Enable IPv6 support in Lima's host resolver
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
    
    mountType = "virtiofs";
    
    networks = [
      {
        # Use vzNAT for native IPv6 support (Apple Virtualization.framework NAT)
        # vzNAT provides automatic IPv6 routing and NAT, unlike socket_vmnet (lima: host)
        vzNAT = true;
        macAddress = "52:55:55:4d:28:2a";
      }
    ];
    
    ssh = {
      forwardAgent = true;
    };
    
    # Ensure cidata/etc_environment provides a PATH where /bin and /usr/bin come first,
    # so the very first sudo resolves to the setuid wrapper at /bin/sudo (symlinked).
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
          SetEnv PATH="/run/wrappers/bin:/run/current-system/sw/binn"
          EOF

          # Ensure main sshd_config includes the drop-in directory very early
          if [ -f /etc/ssh/sshd_config ]; then
            if ! grep -qE '^\s*Include\s+sshd_config.d/\*' /etc/ssh/sshd_config && \
               ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d/\*' /etc/ssh/sshd_config; then
              printf '\nInclude /etc/ssh/sshd_config.d/*\n' >> /etc/ssh/sshd_config
            fi
            # Ensure ~/.ssh/environment is honored immediately
            if ! grep -qE '^\s*PermitUserEnvironment\s+yes' /etc/ssh/sshd_config; then
              printf '\nPermitUserEnvironment yes\n' >> /etc/ssh/sshd_config
            fi
          else
            # Create minimal config if missing
            printf 'Include /etc/ssh/sshd_config.d/*\nPermitUserEnvironment yes\n' > /etc/ssh/sshd_config
          fi

          # Provide BASH_ENV target for non-interactive bash
          install -d -m 755 /etc/profile.d
          cat > /etc/profile.d/noninteractive.sh << 'EOF'
          #!/bin/sh
          export PATH="/run/wrappers/bin:/run/current-system/sw/bin"
          EOF
          chmod 0644 /etc/profile.d/noninteractive.sh

          # Seed user's ~/.ssh/environment with wrapper-first PATH
          install -d -m 700 "/home/${profileUser}/.ssh"
          cat > "/home/${profileUser}/.ssh/environment" << 'EOF'
          PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin
          EOF
          chown -R "${profileUser}:${profileUser}" "/home/${profileUser}/.ssh"

          # Best effort reload if sshd is already up (harmless if not)
          systemctl try-reload-or-restart sshd.service 2>/dev/null || true
          
          # Create a script that sets the correct PATH including wrappers
          mkdir -p /etc/profile.d
          cat > /etc/profile.d/lima-path.sh << 'EOF'
          export PATH="/run/wrappers/bin:/run/current-system/sw/bin:$PATH"
          EOF
          chmod +x /etc/profile.d/lima-path.sh
          
          # Also set it in the systemd environment
          systemctl set-environment PATH="/run/wrappers/bin:/run/current-system/sw/binn"
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
  # Generate lima.yaml in the profile user's home directory
  system.activationScripts.postActivation.text = ''
    : Create Lima configuration directory in profile home
    mkdir -p "${profileHome}/.lima/nerd-nixos"
    
    : Generate lima.yaml with profile user configuration using yq
    cat << 'EOF' | ${pkgs.yq-go}/bin/yq -P -p json -o yaml eval . - > "${profileHome}/.lima/nerd-nixos/lima.yaml"
    ${lib.generators.toJSON {} limaConfig}
    EOF
  '';
}
