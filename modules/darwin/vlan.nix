# VLAN interface provisioning for macOS hosts (@codebase)
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
with lib;
let
  cfg = config.networking.vlan;

  parentInterface = if cfg.parentInterface != null then cfg.parentInterface else "en0";
  vlanName = cfg.name;
  addressPrefix = cfg.addressPrefix;
  netmask = cfg.netmask;
  addressSourceInterface =
    if cfg.addressSourceInterface != null then cfg.addressSourceInterface else parentInterface;

  vlanSetupScript = pkgs.writeShellScript (ndh.store.prefixedName "vlan-setup") (builtins.readFile ./vlan.d/vlan-setup.sh);

  watchPaths = [
    "/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist"
    "/Library/Preferences/SystemConfiguration/preferences.plist"
  ];
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
      default = "en0";
      description = "Parent interface for VLAN tagging (typically en0).";
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

    netmask = mkOption {
      type = types.str;
      default = "255.255.255.0";
      description = "Netmask for the VLAN interface.";
    };
  };

  config = mkIf cfg.enable {
    launchd.daemons.vlan-setup = {
      script = "${vlanSetupScript}";
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = false;
        WatchPaths = watchPaths;
        EnvironmentVariables = {
          VLAN_ID = toString cfg.id;
          VLAN_PARENT = parentInterface;
          ADDRESS_PREFIX = addressPrefix;
          NETMASK = netmask;
          SOURCE_IFACE = addressSourceInterface;
        }
        // lib.optionalAttrs (vlanName != null) { VLAN_NAME = vlanName; };
        StandardOutPath = "/var/log/vlan-setup.log";
        StandardErrorPath = "/var/log/vlan-setup.log";
      };
    };
  };
}
