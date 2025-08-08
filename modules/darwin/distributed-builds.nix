{ self, lib, pkgs, config, ... }:
let
  cfg = config.services.crossHostBuilders;
  hostProfile = config.profile.host;
  hostName = hostProfile.hostName;
  hostAlias = hostProfile.hostAlias or hostName;
  userName = config.profile.user.name;
  userHome = config.profile.user.home;
  
  # SSH key paths for builders (use user's .ssh directory for proper permissions)
  builderKeyPath = "${userHome}/.ssh/keys.d/linux_builder";
  
  # Define remote builders based on hostname
  # These use SSH ProxyJump to reach Linux builder VMs through Darwin hosts
  # Note: bioskop's linux-builder is always preferred (higher speedFactor)
  remoteBuilders = 
    # Always include the local linux-builder
    [{
      hostName = "linux-builder";
      systems = [ "aarch64-linux" ];
      maxJobs = 4;
      # Local builder priority: bioskop local=3, alcide local=2 (fallback)
      speedFactor = if hostAlias == "bioskop" then 3 else 2;
      supportedFeatures = [ "kvm" "benchmark" "big-parallel" ];
      mandatoryFeatures = [ ];
      sshKey = "/etc/nix/builder_ed25519";  # Local builder uses system key
      sshUser = "builder";
      protocol = "ssh-ng";
    }] ++
    # Add remote builders based on current host
    (lib.optional (hostAlias == "bioskop") {
      hostName = "linux-builder-via-alcide";
      systems = [ "aarch64-linux" ];
      maxJobs = 4;
      speedFactor = 2;  # alcide's linux-builder as secondary for bioskop
      supportedFeatures = [ "kvm" "benchmark" "big-parallel" ];
      mandatoryFeatures = [ ];
      sshKey = builderKeyPath;
      sshUser = "builder";
      protocol = "ssh-ng";
    }) ++ 
    (lib.optional (hostAlias == "alcide") {
      hostName = "linux-builder-via-bioskop";
      systems = [ "aarch64-linux" ];
      maxJobs = 4;
      speedFactor = 3;  # bioskop's linux-builder as primary for alcide (remote)
      supportedFeatures = [ "kvm" "benchmark" "big-parallel" ];
      mandatoryFeatures = [ ];
      sshKey = builderKeyPath;
      sshUser = "builder";
      protocol = "ssh-ng";
    });
  
in {
  # Only apply the configuration on Darwin systems when enabled
  config = lib.mkIf (cfg.enable && pkgs.stdenv.isDarwin) {
    # Enable distributed builds
    nix.distributedBuilds = true;
    
    # Override build machines completely - don't let other modules add to it
    nix.buildMachines = lib.mkForce remoteBuilders;
    
    # Manage /etc/nix/machines file for distributed builds
    environment.etc."nix/machines" = lib.mkForce {
      text = lib.concatMapStringsSep "\n" (builder: 
        "${builder.protocol}://${builder.sshUser or "builder"}@${builder.hostName} ${lib.concatStringsSep "," builder.systems} ${builder.sshKey} ${toString builder.maxJobs} ${toString builder.speedFactor} ${lib.concatStringsSep "," builder.supportedFeatures} ${lib.concatStringsSep "," builder.mandatoryFeatures} -"
      ) remoteBuilders;
    };

    # Configure SSH to use Darwin hosts as jump hosts to reach Linux builders
    programs.ssh.extraConfig = ''
      # Linux builder accessible via alcide Darwin host (work profile: stephane.lacoin)
      Host linux-builder-via-alcide
        HostName localhost
        Port 31022
        User builder
        ProxyJump stephane.lacoin@alcide.mammoth-skate.ts.net
        IdentityFile ${userHome}/.ssh/keys.d/linux_builder
        IdentitiesOnly yes
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
        LogLevel QUIET
        # Enable connection multiplexing for faster transfers
        ControlMaster auto
        ControlPath /tmp/ssh-builder-alcide-%r@%h:%p
        ControlPersist 10m
        # Optimize for bulk transfers
        Compression yes
        TCPKeepAlive yes

      # Linux builder accessible via bioskop Darwin host (committed profile: nxmatic)
      Host linux-builder-via-bioskop
        HostName localhost
        Port 31022
        User builder
        ProxyJump nxmatic@bioskop.mammoth-skate.ts.net
        IdentityFile ${userHome}/.ssh/keys.d/linux_builder
        IdentitiesOnly yes
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
        LogLevel QUIET
        # Enable connection multiplexing for faster transfers
        ControlMaster auto
        ControlPath /tmp/ssh-builder-bioskop-%r@%h:%p
        ControlPersist 10m
        # Optimize for bulk transfers
        Compression yes
        TCPKeepAlive yes
    '';
    
    # Ensure builder keys are properly managed in /etc/nix/ only
    environment.etc = {
      "nix/builder_ed25519".source = ../../keys/builder_ed25519;
      "nix/builder_ed25519.pub".source = ../../keys/builder_ed25519.pub;
    };
  };
}
