{ config, pkgs, profile, ... }: {
  imports = [
    ./buildkitd.nix
    ./lima-cloud-init.nix
    ./lima-nixos-configuration.nix
    ./lima-guest-agent.nix
    ./openssh.nix
    ./profile-home-symlinks.nix
    ./rescue.nix
    ./hm-state-dirs.nix
    ./no-bootloader.nix
    ./manual-switch.nix
  ];
}
