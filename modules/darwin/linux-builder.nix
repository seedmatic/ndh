{ self, lib, pkgs, config, ... }:
let
  useCustomConfig = config.linux-builder.useCustomConfig;
  qemu-pkgdb = self.packages.${pkgs.system}.qemu-pkgdb or pkgs.qemu;

  keys = builtins.fromJSON (builtins.readFile (pkgs.runCommand "keys.json" { buildInputs = [ pkgs.yq-go ]; } ''
    yq -o=json '.' ${../home-manager/ssh.d/keys.yaml} > $out
  ''));
  linuxBuilderCommittedPubKey = keys.profiles.committed.linux-builder.public; 
  linuxBuilderCommittedWorkKey = keys.profiles.work.linux-builder.public;
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
        users.users.builder.openssh.authorizedKeys.keys = [ 
          linuxBuilderCommittedPubKey
          linuxBuilderCommittedWorkKey
        ];
      };
    };
  };
}
