{
  config,
  lib,
  ...
}:
let
  ndhUnitPrefix = "io-seedmatic-ndh";
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

  # Declare the contributed target here rather than in systemd/default.nix so
  # modules like modules/nixos/bringup-minimal-system.nix — which only import
  # naming.nix for the ndhSystemd helpers, not the full systemd aggregator —
  # still get a real target to which their units can attach.  Without this
  # declaration on the minimal image, `wantedBy = [ contributedTargetName ]`
  # dangles and systemd drops the dependency, so nothing pulls the service
  # into the boot transaction.
  config.systemd.targets.${mkNdhUnitName "contributed"} = {
    description = "Nix Darwin Home contributed units (@codebase)";
    requires = [ "keys.target" ];
    after = [ "keys.target" ];
    wantedBy = [ "multi-user.target" ];
  };
}
