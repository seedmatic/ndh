{
  config, pkgs, user, ...
}: {
  imports = [ 
    (import ./buildkitd.nix { inherit config pkgs user; })
    ./lima-cloud-init.nix
    ./lima-nixos-configuration.nix
    ./openssh.nix
    ./rescue.nix
  ];
}
