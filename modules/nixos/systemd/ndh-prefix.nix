{ lib }:
let
  ndhUnitPrefix = "io-seedmatic-ndh";
  mkNdhUnitName = suffix:
    if lib.hasPrefix "${ndhUnitPrefix}-" suffix then suffix else "${ndhUnitPrefix}-${suffix}";
  mkNdhServiceName = suffix: "${mkNdhUnitName suffix}.service";
  mkNdhTargetName = suffix: "${mkNdhUnitName suffix}.target";
  contributedTargetName = mkNdhTargetName "contributed";
  attachToContributedTarget = serviceAttrs:
    serviceAttrs // {
      wantedBy = lib.unique ((serviceAttrs.wantedBy or [ ]) ++ [ contributedTargetName ]);
    };
  tailscaleAutoconnectUnitName = mkNdhUnitName "tailscaled-autoconnect";
in
{
  inherit ndhUnitPrefix mkNdhUnitName mkNdhServiceName mkNdhTargetName
    contributedTargetName attachToContributedTarget tailscaleAutoconnectUnitName;
}
