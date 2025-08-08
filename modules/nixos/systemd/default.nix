{ config, pkgs, profile, ... }: {
  imports = [
    ./buildkitd.nix
    ./lima-cloud-init.nix
    ./lima-guest-agent.nix
    ./lima-nixos-configuration.nix
    ./openssh.nix
    ./profile-home-symlinks.nix
    ./rescue.nix
  ];
}
