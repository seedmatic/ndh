# VLAN interface provisioning for NixOS guests (@codebase)
{
  config,
  lib,
  pkgs,
  ndh,
  ndhSystemd,
  ...
}:
with lib;
let
  cfg = config.networking.vlan;

  parentInterface = if cfg.parentInterface != null then cfg.parentInterface else "vmlan0";
  vlanName = cfg.name;
  addressPrefix = cfg.addressPrefix;
  netmaskPrefix = cfg.netmaskPrefix;
  addressSourceInterface =
    if cfg.addressSourceInterface != null then cfg.addressSourceInterface else parentInterface;

  vlanSetupScript = ndh.store.writeShellScriptBin "vlan-setup" (
    builtins.readFile ./vlan.d/vlan-setup.sh
  );
  contributedTargetName = ndhSystemd.contributedTargetName;
  vlanSetupUnitName = ndhSystemd.mkUnitName "vlan-setup";
in
{
  options.networking.vlan = {
    enable = mkEnableOption "VLAN interface provisioning";

    id = mkOption {
      type = types.int;
      default = 2;
      description = "VLAN ID to configure.";
    };

    name = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional interface name for the VLAN (defaults to vlan<ID>).";
    };

    parentInterface = mkOption {
      type = types.nullOr types.str;
      default = "vmlan0";
      description = "Parent interface for VLAN tagging (typically vmlan0 in Lima).";
    };

    addressPrefix = mkOption {
      type = types.str;
      default = "192.168.2";
      description = "IPv4 prefix for VLAN address, without the last octet.";
    };

    addressSourceInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Interface used to derive the last octet (defaults to parentInterface).";
    };

    netmaskPrefix = mkOption {
      type = types.int;
      default = 24;
      description = "Prefix length for the VLAN interface.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.${vlanSetupUnitName} = {
      description = "Configure VLAN interface";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
        Environment = [
          "VLAN_ID=${toString cfg.id}"
          "VLAN_PARENT=${parentInterface}"
          "ADDRESS_PREFIX=${addressPrefix}"
          "NETMASK_PREFIX=${toString netmaskPrefix}"
          "SOURCE_IFACE=${addressSourceInterface}"
        ]
        ++ lib.optionals (vlanName != null) [ "VLAN_NAME=${vlanName}" ];
        ExecStart = "${vlanSetupScript}/bin/vlan-setup";
      };
      wantedBy = [ contributedTargetName ];
    };
  };
}
