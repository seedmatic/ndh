{ self, lib, pkgs, config, ... }:
let
  cfg = config.services.crossHostBuilders;
  hostProfile = config.profile.host;
  hostName = hostProfile.hostName;
  hostAlias = hostProfile.hostAlias or hostName;
  
  # SSH key paths for builders
  builderKeyPath = "/etc/nix/builder_ed25519";
  
  # Define remote builders based on hostname
  remoteBuilders = 
    (lib.optional (hostAlias == "bioskop") {
      hostName = "ssh://builder@alcide.mammoth-skate.ts.net";
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
      hostName = "ssh://builder@bioskop.mammoth-skate.ts.net";
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
  options.services.crossHostBuilders.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable distributed builds to other hosts in the mammoth-skate network";
  };

  config = lib.mkIf cfg.enable {
    # Enable distributed builds
    nix.distributedBuilds = true;
    
    # Configure build machines
    nix.buildMachines = remoteBuilders;
  };
}
