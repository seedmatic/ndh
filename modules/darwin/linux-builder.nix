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
        
        # Builder user gets both the default nix-darwin key and profile keys
        users.users.builder.openssh.authorizedKeys.keys = [ 
          linuxBuilderCommittedPubKey
          linuxBuilderWorkPubKey
        ];
        
        # Deploy profile SSH keys to the VM for additional access methods
        environment.etc = {
          "ssh/builder_committed_ed25519.pub" = {
            text = linuxBuilderCommittedPubKey;
          };
          "ssh/builder_work_ed25519.pub" = {
            text = linuxBuilderWorkPubKey;
          };
        };
      };
    };

    # Deploy current profile's SSH keys to /etc/nix/ for additional authentication options
    # These are separate from the default linux-builder key managed by nix-darwin
    environment.etc = {
      "nix/builder_${currentProfile}_ed25519" = {
        source = pkgs.writeText "builder_${currentProfile}_ed25519" linuxBuilderCurrentPrivKey;
      };
      "nix/builder_${currentProfile}_ed25519.pub" = {
        source = pkgs.writeText "builder_${currentProfile}_ed25519.pub" linuxBuilderCurrentPubKey;
      };
    };

    # Set correct permissions for profile SSH keys via activation script
    system.activationScripts.fixProfileBuilderKeyPermissions = lib.stringAfter [ "etc" ] ''
      chmod 600 /etc/nix/builder_${currentProfile}_ed25519 || true
      chmod 644 /etc/nix/builder_${currentProfile}_ed25519.pub || true
    '';
  };
}
