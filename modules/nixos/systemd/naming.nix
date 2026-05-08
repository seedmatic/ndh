{
  config,
  lib,
  ...
}:
let
  ndhUnitPrefix = "io-nxmatic-nix-darwin-home";
  mkNdhUnitName =
    suffix: if lib.hasPrefix "${ndhUnitPrefix}-" suffix then suffix else "${ndhUnitPrefix}-${suffix}";
  mkNdhServiceName = suffix: "${mkNdhUnitName suffix}.service";
  mkNdhTargetName = suffix: "${mkNdhUnitName suffix}.target";
  contributedTargetName = mkNdhTargetName "contributed";
  attachToContributedTarget =
    serviceAttrs:
    serviceAttrs
    // {
      wantedBy = lib.unique ((serviceAttrs.wantedBy or [ ]) ++ [ contributedTargetName ]);
    };
in
{
  config._module.args.ndhSystemd = {
    unitPrefix = ndhUnitPrefix;
    mkUnitName = mkNdhUnitName;
    mkServiceName = mkNdhServiceName;
    mkTargetName = mkNdhTargetName;
    contributedTargetName = contributedTargetName;
    attachToContributedTarget = attachToContributedTarget;
    tailscaleAutoconnectUnitName = mkNdhUnitName "tailscaled-autoconnect";
  };
}
