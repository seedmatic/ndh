{ self, lib, pkgs, config, ... }:
let
  cfg = config.services.crossHostBuilders;
  hostProfile = config.profile.host;
  hostName = hostProfile.hostName;
  hostAlias = hostProfile.hostAlias or hostName;
  userName = config.profile.user.name;
  userHome = config.profile.user.home;
  
  # SSH key paths for builders (use user's .ssh directory for proper permissions)
  builderKeyPath = "${userHome}/.ssh/keys.d/builder_ed25519";
  
  # Define remote builders based on hostname
  # These use SSH ProxyJump to reach Linux builder VMs through Darwin hosts
  # Note: Each host connects to the OTHER host's Linux builder
  remoteBuilders = 
    # Always include the local linux-builder
    [{
      hostName = "linux-builder";
      systems = [ "aarch64-linux" ];
      maxJobs = 4;
      speedFactor = 2;  # Local builder is faster
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
      speedFactor = 1;
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
      speedFactor = 1;
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
        IdentityFile ${userHome}/.ssh/keys.d/builder_ed25519
        IdentitiesOnly yes
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
        LogLevel QUIET

      # Linux builder accessible via bioskop Darwin host (committed profile: nxmatic)
      Host linux-builder-via-bioskop
        HostName localhost
        Port 31022
        User builder
        ProxyJump nxmatic@bioskop.mammoth-skate.ts.net
        IdentityFile ${userHome}/.ssh/keys.d/builder_ed25519
        IdentitiesOnly yes
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
        LogLevel QUIET
    '';
    
    # Ensure builder keys are properly managed in /etc/nix/ only
    environment.etc = {
      "nix/builder_ed25519".source = ../../keys/builder_ed25519;
      "nix/builder_ed25519.pub".source = ../../keys/builder_ed25519.pub;
    };
  };
}
