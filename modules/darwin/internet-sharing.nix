# Internet Sharing configuration module (@codebase)
# Manages macOS Internet Sharing NAT for Lima VM bridge networks
# This creates the com.apple.internet-sharing pf anchors that provide NAT

{
  config,
  lib,
  pkgs,
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

  # Plist configuration for Internet Sharing
  natConfig = {
    NAT = {
      Enabled = if cfg.enable then 1 else 0;
      PrimaryInterface = cfg.primaryInterface;
      SharingDevices = cfg.sharingDevices;
    };
  };

  plistPath = "/Library/Preferences/SystemConfiguration/com.apple.nat.plist";

  # Script to configure Internet Sharing plist
  # Note: This writes the config but cannot activate it programmatically due to SIP.
  # User must manually toggle Internet Sharing in System Settings after first activation.
  configurePlist = pkgs.writeShellScript "configure-internet-sharing" ''
    set -euo pipefail
    LOG="/var/log/darwin-internet-sharing.log"
    echo "[internetSharing] start $(date)" >> "$LOG"

    # Check if configuration needs updating
    NEEDS_UPDATE=0

    if [ ! -f "${plistPath}" ]; then
      echo "[internetSharing] plist missing, creating new configuration" >> "$LOG"
      NEEDS_UPDATE=1
    else
      # Check if enabled state matches
      CURRENT_ENABLED=$(defaults read "${plistPath}" NAT -dict 2>/dev/null | grep -o 'Enabled = [01]' | cut -d' ' -f3 || echo "")
      DESIRED_ENABLED="${toString (if cfg.enable then 1 else 0)}"
      if [ "$CURRENT_ENABLED" != "$DESIRED_ENABLED" ]; then
        echo "[internetSharing] enabled state differs (current=$CURRENT_ENABLED, desired=$DESIRED_ENABLED)" >> "$LOG"
        NEEDS_UPDATE=1
      fi

      # Check if primary interface matches
      CURRENT_IFACE=$(defaults read "${plistPath}" NAT -dict 2>/dev/null | grep -o 'PrimaryInterface = "[^"]*"' | cut -d'"' -f2 || echo "")
      if [ "$CURRENT_IFACE" != "${cfg.primaryInterface}" ]; then
        echo "[internetSharing] primary interface differs (current=$CURRENT_IFACE, desired=${cfg.primaryInterface})" >> "$LOG"
        NEEDS_UPDATE=1
      fi

      # Check if sharing devices match
      CURRENT_DEVICES=$(defaults read "${plistPath}" NAT -dict 2>/dev/null | grep -A10 'SharingDevices' | grep -o 'bridge[0-9]*' | sort | tr '\n' ',' || echo "")
      DESIRED_DEVICES="${lib.concatStringsSep "," (lib.sort (a: b: a < b) cfg.sharingDevices)}"
      if [ "$CURRENT_DEVICES" != "$DESIRED_DEVICES," ]; then
        echo "[internetSharing] sharing devices differ (current=$CURRENT_DEVICES, desired=$DESIRED_DEVICES)" >> "$LOG"
        NEEDS_UPDATE=1
      fi
    fi

    if [ $NEEDS_UPDATE -eq 0 ]; then
      echo "[internetSharing] configuration already matches desired state" >> "$LOG"
      echo "[internetSharing] end $(date)" >> "$LOG"
      exit 0
    fi

    # Write new configuration
    echo "[internetSharing] writing new configuration" >> "$LOG"

    # Clear existing NAT dict if present
    defaults delete "${plistPath}" NAT 2>/dev/null || true

    # Create NAT dictionary with basic settings
    defaults write "${plistPath}" NAT -dict-add Enabled -bool ${if cfg.enable then "true" else "false"}
    defaults write "${plistPath}" NAT -dict-add PrimaryInterface -string "${cfg.primaryInterface}"

    # Add sharing devices array using PlistBuddy (defaults can't handle nested arrays properly)
    /usr/libexec/PlistBuddy -c "Delete :NAT:SharingDevices" "${plistPath}" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :NAT:SharingDevices array" "${plistPath}"
    ${lib.concatMapStringsSep "\n" (device: ''
      /usr/libexec/PlistBuddy -c "Add :NAT:SharingDevices:$ string ${device}" "${plistPath}"
    '') cfg.sharingDevices}

    # Verify written configuration
    echo "[internetSharing] configuration written:" >> "$LOG"
    defaults read "${plistPath}" NAT >> "$LOG" 2>&1

    ${lib.optionalString cfg.autoToggle ''
      # Attempt to signal NetworkSharing daemon (will fail with SIP, but try anyway)
      echo "[internetSharing] attempting to signal NetworkSharing daemon" >> "$LOG"
      if launchctl kickstart -k system/com.apple.NetworkSharing >> "$LOG" 2>&1; then
        echo "[internetSharing] successfully signaled NetworkSharing daemon" >> "$LOG"
      else
        echo "[internetSharing][WARN] cannot restart NetworkSharing (SIP restriction)" >> "$LOG"
        echo "[internetSharing][ACTION REQUIRED] manually toggle Internet Sharing in System Settings:" >> "$LOG"
        echo "[internetSharing]   System Settings → General → Sharing → Internet Sharing" >> "$LOG"
        echo "[internetSharing]   Share from: ${cfg.primaryInterface}, To: ${lib.concatStringsSep ", " cfg.sharingDevices}" >> "$LOG"
      fi
    ''}

    echo "[internetSharing] end $(date)" >> "$LOG"
  '';

  activationWrapperScript = pkgs.writeShellScript "internet-sharing-activation.sh" ''
    set -euo pipefail
    LOG="/var/log/darwin-internet-sharing-activation.log"
    {
      echo "[internetSharing] configuring Internet Sharing NAT"
      ${configurePlist}

      ${lib.optionalString cfg.verifyAnchors ''
        if pfctl -s nat 2>/dev/null | grep -q 'nat-anchor "com.apple.internet-sharing"'; then
          echo "[internetSharing] ✓ NAT anchors active"
        else
          echo "[internetSharing][WARN] NAT anchors NOT active - manual toggle required"
          echo "[internetSharing][WARN] Go to: System Settings → General → Sharing → Internet Sharing"
        fi
      ''}
    } >>"$LOG" 2>&1
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

  config = mkIf cfg.enable {
    # Run configuration script during system activation
    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${activationWrapperScript}
    '';

    # Document the configuration in system profile
    system.defaults.CustomUserPreferences = {
      "README-InternetSharing" = {
        Note = "Internet Sharing configured by nix-darwin";
        PrimaryInterface = cfg.primaryInterface;
        SharingDevices = cfg.sharingDevices;
        ManualToggleRequired = "System Settings → General → Sharing → Internet Sharing";
      };
    };
  };
}
