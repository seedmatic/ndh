{ self, lib, pkgs, config, ... }:
let
  cfg = config.services.crossHostBuilders;
  hostProfile = config.profile.host;
  hostName = hostProfile.hostName;
  # Avoid forcing an unset option value: only use hostAlias if attribute exists and is non-empty
  hostAlias = if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "")
    then hostProfile.hostAlias
    else hostName;
  userName = config.profile.user.name;
  userHome = config.profile.user.home;
  
  # SSH key paths for builders (now stored under /etc/nix/keys.d)
  builderKeyPath = "/etc/nix/keys.d/builder_ed25519";
  controlMasterPath = "/nix/var/nix/userpool/ssh-builder-%r@%h:%p";
  
  # Define remote builders based on hostname
  # alcide no longer hosts a linux builder; delegate to bioskop's exposed builder port
  bioskopDarwinBuilder = {
    hostName = "darwin-builder-via-lan";
    systems = [ "aarch64-darwin" ];
    maxJobs = 4;
    speedFactor = 3;
    supportedFeatures = [ "benchmark" "big-parallel" ];
    mandatoryFeatures = [ ];
    protocol = "ssh-ng";
  };

  bioskopLinuxBuilder = {
    # Use ssh so the per-host port from ssh_config is honored
    hostName = "linux-builder-via-lan";
    systems = [ "aarch64-linux" ];
    maxJobs = 8;
    speedFactor = 3;  # bioskop is now the primary linux builder
    supportedFeatures = [ "kvm" "benchmark" "big-parallel" ];
    mandatoryFeatures = [ ];
    protocol = "ssh-ng";
  };

  remoteBuilders =
    # alcide delegates to bioskop for both Darwin and Linux builds
    (lib.optional (hostAlias == "alcide") bioskopDarwinBuilder)
    ++ (lib.optional (hostAlias == "alcide") bioskopLinuxBuilder);
  
in {
  # Only apply the configuration on Darwin systems when enabled
  config = lib.mkIf (cfg.enable && pkgs.stdenv.isDarwin) {
    # Enable distributed builds
    nix.distributedBuilds = true;
    
    # Override build machines completely - don't let other modules add to it
    nix.buildMachines = lib.mkForce remoteBuilders;

    # Force remote-only builds and let builders use caches directly
    nix.settings = {
      max-jobs = lib.mkForce 0;               # never build locally
      builders-use-substitutes = true;        # allow builders to pull from caches
      fallback = false;                       # fail rather than silently build locally
    };

    # Replace inline ssh extraConfig with drop-in file for clarity
    environment.etc."ssh/ssh_config.d/60-builders.conf".text = ''
# Builder host stanzas (@codebase)
Host darwin-builder-via-lan
  HostName bioskop.lan
  Port 22
  User builder
  IdentityFile ${builderKeyPath}
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel QUIET
  ConnectTimeout 10
  ServerAliveInterval 30
  ServerAliveCountMax 3
  ControlMaster auto
  ControlPath ${controlMasterPath}
  ControlPersist 10m
  Compression yes
  TCPKeepAlive yes

Host linux-builder-via-lan
  HostName bioskop.lan
  Port 31022
  User builder
  IdentityFile ${builderKeyPath}
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel QUIET
  ConnectTimeout 10
  ServerAliveInterval 30
  ServerAliveCountMax 3
  ControlMaster auto
  ControlPath ${controlMasterPath}
  ControlPersist 10m
  Compression yes
  TCPKeepAlive yes
'';
  };
}
