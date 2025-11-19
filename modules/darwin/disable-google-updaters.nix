{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.disable-google-updaters;
in
{
  options.services.disable-google-updaters = {
    enable = mkEnableOption "automatic disabling of Google update services (Keystone, Google Updater)";
  };

  config = mkIf cfg.enable {
    # Add the script to system packages
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "disable-google-updaters" ''
        # Disable Google Keystone and Updater services
        # These services periodically add Google LLC entries and trigger notifications

        echo "Disabling Google update services..."

        # Unload user-level agents (if any)
        if [ -f ~/Library/LaunchAgents/com.google.keystone.agent.plist ]; then
            launchctl unload -w ~/Library/LaunchAgents/com.google.keystone.agent.plist 2>/dev/null || true
            echo "  ✓ Unloaded user keystone agent"
        fi

        # Unload system-level agents (requires sudo)
        if [ -f /Library/LaunchAgents/com.google.keystone.xpcservice.plist ]; then
            sudo launchctl unload -w /Library/LaunchAgents/com.google.keystone.xpcservice.plist 2>/dev/null || true
            echo "  ✓ Unloaded keystone xpcservice"
        fi

        if [ -f /Library/LaunchAgents/com.google.keystone.agent.plist ]; then
            sudo launchctl unload -w /Library/LaunchAgents/com.google.keystone.agent.plist 2>/dev/null || true
            echo "  ✓ Unloaded system keystone agent"
        fi

        # Unload system-level daemons (requires sudo)
        if [ -f /Library/LaunchDaemons/com.google.keystone.daemon.plist ]; then
            sudo launchctl unload -w /Library/LaunchDaemons/com.google.keystone.daemon.plist 2>/dev/null || true
            echo "  ✓ Unloaded keystone daemon"
        fi

        if [ -f /Library/LaunchDaemons/com.google.GoogleUpdater.wake.system.plist ]; then
            sudo launchctl unload -w /Library/LaunchDaemons/com.google.GoogleUpdater.wake.system.plist 2>/dev/null || true
            echo "  ✓ Unloaded Google updater wake daemon"
        fi

        echo "✓ Google update services disabled"
        echo ""
        echo "Note: These services may be re-created when you update Google Chrome or other Google apps."
      '')
    ];

    # Automatically run on system activation
    system.activationScripts.postActivation.text = mkAfter ''
      # Disable Google update services
      echo "Checking for Google update services..."
      
      # Check if any Google updater services exist
      if [ -f /Library/LaunchAgents/com.google.keystone.xpcservice.plist ] || \
         [ -f /Library/LaunchAgents/com.google.keystone.agent.plist ] || \
         [ -f /Library/LaunchDaemons/com.google.keystone.daemon.plist ] || \
         [ -f /Library/LaunchDaemons/com.google.GoogleUpdater.wake.system.plist ]; then
        
        echo "Found Google update services, disabling..."
        
        # Unload system-level agents
        [ -f /Library/LaunchAgents/com.google.keystone.xpcservice.plist ] && \
          sudo launchctl unload -w /Library/LaunchAgents/com.google.keystone.xpcservice.plist 2>/dev/null || true
        
        [ -f /Library/LaunchAgents/com.google.keystone.agent.plist ] && \
          sudo launchctl unload -w /Library/LaunchAgents/com.google.keystone.agent.plist 2>/dev/null || true
        
        # Unload system-level daemons
        [ -f /Library/LaunchDaemons/com.google.keystone.daemon.plist ] && \
          sudo launchctl unload -w /Library/LaunchDaemons/com.google.keystone.daemon.plist 2>/dev/null || true
        
        [ -f /Library/LaunchDaemons/com.google.GoogleUpdater.wake.system.plist ] && \
          sudo launchctl unload -w /Library/LaunchDaemons/com.google.GoogleUpdater.wake.system.plist 2>/dev/null || true
        
        echo "✓ Google update services disabled"
      else
        echo "No Google update services found"
      fi
    '';
  };
}
