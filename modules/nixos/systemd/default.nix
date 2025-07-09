{ config, pkgs, profile, ... }: {
  imports = [
    ./buildkitd.nix
    ./lima-cloud-init.nix
    ./lima-nixos-configuration.nix
    ./openssh.nix
    ./rescue.nix
  ];
}
