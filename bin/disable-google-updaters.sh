#!/usr/bin/env bash
# Disable Google Keystone and Updater services
# These services periodically add Google LLC entries and trigger notifications

set -e

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
echo "You can run this script again to disable them."
