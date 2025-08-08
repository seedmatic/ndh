# Lima configuration generator (@codebase)
# Generates lima.yaml with profile-aware user configuration

{ config, pkgs, lib, ... }:

let
  profileUser = config.profile.user.name;
  
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
        lima = "host";
        macAddress = "52:55:55:4d:28:2a";
      }
    ];
    
    ssh = {
      forwardAgent = true;
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
          
          # Ensure /usr/local/bin exists
          mkdir -p /usr/local/bin
          
          # Create early symlinks for critical binaries including sudo
          ln -sf /run/wrappers/bin/sudo /usr/local/bin/sudo || true
          ln -sf /run/current-system/sw/bin/bash /usr/local/bin/bash || true
          
          # Set PATH in ssh daemon environment - for non-interactive SSH commands
          mkdir -p /etc/ssh/sshd_config.d
          cat > /etc/ssh/sshd_config.d/lima-path.conf << 'EOF'
          SetEnv PATH="/run/wrappers/bin:/usr/local/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin"
          EOF
          
          # Create a script that sets the correct PATH including wrappers
          mkdir -p /etc/profile.d
          cat > /etc/profile.d/lima-path.sh << 'EOF'
          export PATH="/run/wrappers/bin:/run/current-system/sw/bin:$PATH"
          EOF
          chmod +x /etc/profile.d/lima-path.sh
          
          # Also set it in the systemd environment
          systemctl set-environment PATH="/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
          
          # Create lima-ssh-ready file immediately since basic system is ready
          if [[ -f /mnt/lima-cidata/meta-data ]]; then
            cp /mnt/lima-cidata/meta-data /run/lima-ssh-ready
            chmod 644 /run/lima-ssh-ready
          fi
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
  # Generate lima.yaml in the correct user directory
  # Note: On Darwin, we use the Darwin user's home, not the profile user's home
  # The profile user is for the NixOS guest, while Lima runs on the Darwin host
  system.activationScripts.generateLimaConfig = {
    text = ''
      : Create Lima configuration directory
      mkdir -p "$HOME/.lima/nerd-nixos"
      
      : Generate lima.yaml with profile user configuration
      cat > "$HOME/.lima/nerd-nixos/lima.yaml" << 'EOF'
${lib.generators.toYAML {} limaConfig}
EOF
    '';
  };
}
