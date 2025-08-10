{ self, lib, pkgs, config, ... }:
let
  useCustomConfig = config.linux-builder.useCustomConfig;
  qemu-pkgdb = self.packages.${pkgs.system}.qemu-pkgdb or pkgs.qemu;

  keys = lib.importYAML ./ssh.d/keys.yaml;
  linuxBuilderCommittedPubKey = keys.profiles.committed.linux-builder.public; 
  linuxBuilderCommittedWorkKey = keys.profiles.committed.linux-builder.work;
in {
  options.linux-builder.useCustomConfig = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable custom config for linux-builder";
  };

  config = {
    # SSH keys are managed by distributed-builds.nix at /etc/nix/builder_ed25519
    
    nix.linux-builder = {
      enable = true;
      ephemeral = true;
      maxJobs = 4;
      systems = [ "aarch64-linux" ];
      protocol = "ssh-ng";
      speedFactor = 1;
      supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
      mandatoryFeatures = [];
      config = {
        virtualisation.darwin-builder.hostPort = 31022;
        services.openssh.authorizedKeys.keys = [ linuxBuilderCommittedPubKey
          linuxBuilderCommittedWorkKey
        ];
      };
    };
  };
}
