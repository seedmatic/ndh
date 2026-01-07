{
  config,
  pkgs,
  profile,
  lib,
  ...
}:
{
  options.rescue.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable rescue-mode tooling and units (off by default; enable per-host).";
  };

  imports = [
    ./buildkitd.nix
    ./lima-cloud-init.nix
    ./lima-nixos-configuration.nix
    ./lima-guest-agent.nix
    ./openssh.nix
    ./hm-state-dirs.nix
    ./rescue.nix
  ];
}
