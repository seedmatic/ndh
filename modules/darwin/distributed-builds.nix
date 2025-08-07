{ self, lib, pkgs, config, ... }:
let
  cfg = config.services.crossHostBuilders;
  hostProfile = config.profile.host;
  hostName = hostProfile.hostName;
  hostAlias = hostProfile.hostAlias or hostName;
  
  # SSH key paths for builders
  builderKeyPath = "/etc/nix/builder_ed25519";
  
  # Define remote builders based on hostname
  # These use SSH ProxyJump to reach Linux builder VMs through Darwin hosts
  remoteBuilders = 
    (lib.optional (hostAlias == "bioskop") {
      hostName = "ssh://linux-builder-via-alcide";
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
      hostName = "ssh://linux-builder-via-bioskop";
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
    
    # Configure build machines
    nix.buildMachines = remoteBuilders;

    # Configure SSH to use Darwin hosts as jump hosts to reach Linux builders
    programs.ssh.extraConfig = ''
      # Linux builder accessible via alcide Darwin host
      Host linux-builder-via-alcide
        HostName linux-builder
        User builder
        ProxyJump ${config.profile.user.name}@alcide.mammoth-skate.ts.net
        IdentityFile /etc/nix/builder_ed25519
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
        LogLevel QUIET

      # Linux builder accessible via bioskop Darwin host  
      Host linux-builder-via-bioskop
        HostName linux-builder
        User builder
        ProxyJump ${config.profile.user.name}@bioskop.mammoth-skate.ts.net
        IdentityFile /etc/nix/builder_ed25519
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
