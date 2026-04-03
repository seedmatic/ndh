{
  config,
  pkgs,
  profile,
  lib,
  hostProfile ? { },
  ...
}:
let
  hostImageMode =
    if hostProfile ? nixosImageMode && hostProfile.nixosImageMode != null then
      hostProfile.nixosImageMode
    else
      "full";
  bootstrapMode = hostImageMode == "bootstrap";
in
{
  options.rescue.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable rescue-mode tooling and units (off by default; enable per-host).";
  };

  imports = [
    ./lima-cloud-init.nix
    ./lima-nixos-configuration.nix
    ./lima-guest-agent.nix
    ./openssh.nix
    ./rescue.nix
  ]
  ++ (lib.optionals (!bootstrapMode) [
    ./buildkitd.nix
    ./hm-state-dirs.nix
  ]);
}
