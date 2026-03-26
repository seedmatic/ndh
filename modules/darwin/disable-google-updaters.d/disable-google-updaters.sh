#!/usr/bin/env bash
# Disable Google Keystone and Updater services
# These services periodically add Google LLC entries and trigger notifications

set -euo pipefail

# Ensure system-level daemons are completely removed so they cannot respawn automatically.
disable_system_daemon() {
    local label="$1"
    local plist="$2"

    if [ ! -f "$plist" ]; then
        return
    fi

    if sudo launchctl list | grep -q "$label" 2>/dev/null; then
        sudo launchctl bootout "system/$label" 2>/dev/null || \
            sudo launchctl unload -w "$plist" 2>/dev/null || true
        echo "  ✓ Unloaded $label"
    else
        sudo launchctl unload -w "$plist" 2>/dev/null || true
    fi

    sudo launchctl disable "system/$label" 2>/dev/null || true
    sudo rm -f "$plist" 2>/dev/null || true
    echo "  ✓ Disabled $label (removed $(basename "$plist"))"
}

echo "Checking for Google update services..."

# Track if we found any services
found_services=false

# Check if any services exist
if [ -f ~/Library/LaunchAgents/com.google.keystone.agent.plist ] || \
   [ -f /Library/LaunchAgents/com.google.keystone.xpcservice.plist ] || \
   [ -f /Library/LaunchAgents/com.google.keystone.agent.plist ] || \
   [ -f /Library/LaunchDaemons/com.google.keystone.daemon.plist ] || \
   [ -f /Library/LaunchDaemons/com.google.GoogleUpdater.wake.system.plist ]; then
    found_services=true
fi

if [ "$found_services" = false ]; then
    echo "No Google update services found"
    exit 0
fi

echo "Found Google update services, disabling..."

# Unload user-level agents (if any)
if [ -f ~/Library/LaunchAgents/com.google.keystone.agent.plist ]; then
    if launchctl list | grep -q com.google.keystone.agent 2>/dev/null; then
        launchctl unload -w ~/Library/LaunchAgents/com.google.keystone.agent.plist 2>/dev/null || true
        echo "  ✓ Unloaded user keystone agent"
    else
        launchctl unload -w ~/Library/LaunchAgents/com.google.keystone.agent.plist 2>/dev/null || true
    fi
fi

# Unload system-level agents (requires sudo)
if [ -f /Library/LaunchAgents/com.google.keystone.xpcservice.plist ]; then
    if launchctl list | grep -q com.google.keystone.xpcservice 2>/dev/null; then
        sudo launchctl unload -w /Library/LaunchAgents/com.google.keystone.xpcservice.plist 2>/dev/null || true
        echo "  ✓ Unloaded keystone xpcservice"
    else
        sudo launchctl unload -w /Library/LaunchAgents/com.google.keystone.xpcservice.plist 2>/dev/null || true
    fi
fi

if [ -f /Library/LaunchAgents/com.google.keystone.agent.plist ]; then
    if launchctl list | grep -q com.google.keystone.agent 2>/dev/null; then
        sudo launchctl unload -w /Library/LaunchAgents/com.google.keystone.agent.plist 2>/dev/null || true
        echo "  ✓ Unloaded system keystone agent"
    else
        sudo launchctl unload -w /Library/LaunchAgents/com.google.keystone.agent.plist 2>/dev/null || true
    fi
fi

# Unload system-level daemons (requires sudo)
disable_system_daemon "com.google.keystone.daemon" \
    "/Library/LaunchDaemons/com.google.keystone.daemon.plist"
disable_system_daemon "com.google.GoogleUpdater.wake.system" \
    "/Library/LaunchDaemons/com.google.GoogleUpdater.wake.system.plist"

echo "✓ Google update services disabled"
echo ""
echo "Note: These services may be re-created when you update Google Chrome or other Google apps."
echo "You can run this script again to disable them."
