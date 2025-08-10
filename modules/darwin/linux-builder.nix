{ self, lib, pkgs, config, ... }:
let
  qemu-pkgdb = self.packages.${pkgs.system}.qemu-pkgdb or pkgs.qemu;

  keys = builtins.fromJSON (builtins.readFile (pkgs.runCommand "keys.json" { buildInputs = [ pkgs.yq-go ]; } ''
    yq -o=json '.' ${../home-manager/ssh.d/keys.yaml} > $out
  ''));
  
  # Get current profile name
  currentProfile = config.profile.name;
  
  # Get SSH keys for current profile
  linuxBuilderCurrentPubKey = keys.profiles.${currentProfile}.linux-builder.public;
  linuxBuilderCurrentPrivKey = keys.profiles.${currentProfile}.linux-builder.private;
  
  # Also get keys for both profiles for VM authorized_keys
  linuxBuilderCommittedPubKey = keys.profiles.committed.linux-builder.public; 
  linuxBuilderWorkPubKey = keys.profiles.work.linux-builder.public;
in {

  config = {    
    nix.linux-builder = {
      enable = true;
      ephemeral = true;
      workingDirectory = "/var/lib/linux-builder";
      maxJobs = 4;
      systems = [ "aarch64-linux" ];
      protocol = "ssh-ng";
      speedFactor = 1;
      supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
      mandatoryFeatures = [];
      config = {
        virtualisation.darwin-builder.hostPort = 31022;
        
        # Configure SSH daemon to also check our profile keys file
        services.openssh.authorizedKeysFiles = [
          "/var/keys/%u_ed25519.pub"           # Original nix-darwin key location  
          "/etc/ssh/builder_profile_keys.pub"  # Our profile keys location in /etc
          "%h/.ssh/authorized_keys"            # Standard user location
          "/etc/ssh/authorized_keys.d/%u"      # System location
        ];
        
        # Deploy profile SSH keys to the VM using NixOS environment.etc with mode
        environment.etc = {
          "ssh/builder_profile_keys.pub" = {
            text = ''
              ssh-ed25519 ${linuxBuilderCommittedPubKey} committed-profile
              ssh-ed25519 ${linuxBuilderWorkPubKey} work-profile
            '';
            mode = "0644";
          };
        };
      };
    };

    # SSH keys are managed by the home-manager ssh-keys.nix module
    # Keys are deployed to ~/.ssh/keys.d/ with proper permissions
  };
}
