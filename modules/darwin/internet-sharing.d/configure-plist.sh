set -euo pipefail
LOG="/var/log/darwin-internet-sharing.log"
echo "[internetSharing] start $(date)" >> "$LOG"

# Check if configuration needs updating
NEEDS_UPDATE=0

if [ ! -f "@plistPath@" ]; then
  echo "[internetSharing] plist missing, creating new configuration" >> "$LOG"
  NEEDS_UPDATE=1
else
  CURRENT_ENABLED=$(defaults read "@plistPath@" NAT -dict 2>/dev/null | grep -o 'Enabled = [01]' | cut -d' ' -f3 || echo "")
  if [ "$CURRENT_ENABLED" != "@desiredEnabled@" ]; then
    echo "[internetSharing] enabled state differs (current=$CURRENT_ENABLED, desired=@desiredEnabled@)" >> "$LOG"
    NEEDS_UPDATE=1
  fi

  CURRENT_IFACE=$(defaults read "@plistPath@" NAT -dict 2>/dev/null | grep -o 'PrimaryInterface = "[^"]*"' | cut -d'"' -f2 || echo "")
  if [ "$CURRENT_IFACE" != "@primaryInterface@" ]; then
    echo "[internetSharing] primary interface differs (current=$CURRENT_IFACE, desired=@primaryInterface@)" >> "$LOG"
    NEEDS_UPDATE=1
  fi

  CURRENT_DEVICES=$(defaults read "@plistPath@" NAT -dict 2>/dev/null | grep -A10 'SharingDevices' | grep -o 'bridge[0-9]*' | sort | tr '\n' ',' || echo "")
  DESIRED_DEVICES="@desiredDevices@"
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

echo "[internetSharing] writing new configuration" >> "$LOG"

defaults delete "@plistPath@" NAT 2>/dev/null || true

defaults write "@plistPath@" NAT -dict-add Enabled -bool @enableFlag@
defaults write "@plistPath@" NAT -dict-add PrimaryInterface -string "@primaryInterface@"

/usr/libexec/PlistBuddy -c "Delete :NAT:SharingDevices" "@plistPath@" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NAT:SharingDevices array" "@plistPath@"
@sharingDevicesCmds@

echo "[internetSharing] configuration written:" >> "$LOG"
defaults read "@plistPath@" NAT >> "$LOG" 2>&1

@autoToggleBlock@

echo "[internetSharing] end $(date)" >> "$LOG"
