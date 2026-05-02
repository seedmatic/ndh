# Internet Sharing configuration module (@codebase)
# Manages macOS Internet Sharing NAT for Lima VM bridge networks
# This creates the com.apple.internet-sharing pf anchors that provide NAT

{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:

let
  inherit (lib)
    mkOption
    mkIf
    types
    mkMerge
    ;
  cfg = config.internetSharing;
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  loggerScript = config.nixBashLogger.script;

  # Plist configuration for Internet Sharing
  natConfig = {
    NAT = {
      Enabled = if cfg.enable then 1 else 0;
      PrimaryInterface = cfg.primaryInterface;
      SharingDevices = cfg.sharingDevices;
    };
  };

  plistPath = "/Library/Preferences/SystemConfiguration/com.apple.nat.plist";
  desiredDevices = lib.concatStringsSep "," (lib.sort (a: b: a < b) cfg.sharingDevices);

  sharingDevicesCmds = lib.concatMapStringsSep "\n" (device: ''
    /usr/libexec/PlistBuddy -c "Add :NAT:SharingDevices:$ string ${device}" "${plistPath}"
  '') cfg.sharingDevices;

  autoToggleBlock = lib.optionalString cfg.autoToggle ''
    echo "[internetSharing] attempting to signal NetworkSharing daemon" >> "$LOG"
    if launchctl kickstart -k system/com.apple.NetworkSharing >> "$LOG" 2>&1; then
      echo "[internetSharing] successfully signaled NetworkSharing daemon" >> "$LOG"
    else
      echo "[internetSharing][WARN] cannot restart NetworkSharing (SIP restriction)" >> "$LOG"
      echo "[internetSharing][ACTION REQUIRED] manually toggle Internet Sharing in System Settings:" >> "$LOG"
      echo "[internetSharing]   System Settings → General → Sharing → Internet Sharing" >> "$LOG"
      echo "[internetSharing]   Share from: ${cfg.primaryInterface}, To: ${lib.concatStringsSep ", " cfg.sharingDevices}" >> "$LOG"
    fi
  '';

  verifyAnchorsBlock = lib.optionalString cfg.verifyAnchors ''
    if pfctl -s nat 2>/dev/null | grep -q 'nat-anchor "com.apple.internet-sharing"'; then
      echo "[internetSharing] ✓ NAT anchors active"
    else
      echo "[internetSharing][WARN] NAT anchors NOT active - manual toggle required"
      echo "[internetSharing][WARN] Go to: System Settings → General → Sharing → Internet Sharing"
    fi
  '';

  configurePlistPkg = ndh.store.installBinScript "internet-sharing-configure-plist" (
    pkgs.replaceVars ./internet-sharing.d/configure-plist.sh {
      nixBashTrampoline = nixBashTrampoline;
      desiredEnabled = lib.toString (if cfg.enable then 1 else 0);
      enableFlag = if cfg.enable then "true" else "false";
      primaryInterface = cfg.primaryInterface;
      inherit
        plistPath
        sharingDevicesCmds
        desiredDevices
        autoToggleBlock
        ;
    }
  );
  configurePlist = "${configurePlistPkg}/bin/internet-sharing-configure-plist";

  activationWrapperScript = ndh.store.runCommand "internet-sharing-activation" { } ''
    install -Dm755 ${
      pkgs.replaceVars ./internet-sharing.d/activation-wrapper.sh {
        nixBashTrampoline = nixBashTrampoline;
        inherit configurePlist verifyAnchorsBlock;
      }
    } "$out/bin/internet-sharing-activation"
  '';

in
{
  options.internetSharing = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable Internet Sharing NAT for Lima VM bridge networks.
        This configures /Library/Preferences/SystemConfiguration/com.apple.nat.plist
        to enable NAT from the primary interface to the specified sharing devices.

        Note: Due to System Integrity Protection (SIP), the NetworkSharing daemon
        cannot be restarted programmatically. After first activation or configuration
        changes, you must manually toggle Internet Sharing in System Settings:
          System Settings → General → Sharing → Internet Sharing

        Once toggled, the pf anchors (com.apple.internet-sharing) will be created
        automatically and provide NAT for the configured bridge networks.
      '';
    };

    primaryInterface = mkOption {
      type = types.str;
      default = "en0";
      description = ''
        Primary network interface to share internet from (typically en0 for Ethernet/WiFi).
        This is the WAN interface with upstream internet connectivity.
      '';
    };

    sharingDevices = mkOption {
      type = types.listOf types.str;
      default = [ "bridge101" ];
      description = ''
        List of network interfaces to share internet to.
        For Lima VM bridge networks, this is typically ["bridge101"].
        Multiple bridges can be specified if running multiple Lima instances.
      '';
    };

    autoToggle = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Attempt to automatically restart the NetworkSharing daemon after
        configuration changes. This will fail with SIP enabled but is
        included for completeness. Set to false to skip the attempt.
      '';
    };

    verifyAnchors = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Verify that com.apple.internet-sharing pf anchors are active after
        activation. If anchors are missing, log a warning with manual toggle
        instructions. This check helps ensure Internet Sharing is properly
        configured and activated.
      '';
    };
  };

  config = mkIf cfg.enable (
    {
      # Run configuration script during system activation (networking fragment)
      system.activationScripts.networking.text = lib.mkAfter ''
        ${activationWrapperScript}/bin/internet-sharing-activation
      '';
    }
    // {
      system.defaults.CustomUserPreferences = {
        "README-InternetSharing" = {
          Note = "Internet Sharing configured by nix-darwin";
          PrimaryInterface = cfg.primaryInterface;
          SharingDevices = cfg.sharingDevices;
          ManualToggleRequired = "System Settings → General → Sharing → Internet Sharing";
        };
      };
    }
  );
}
