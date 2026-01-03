#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
  echo "[internetSharing] start $(date)"

  # Check if configuration needs updating
  NEEDS_UPDATE=0

  if [ ! -f "@plistPath@" ]; then
    echo "[internetSharing] plist missing, creating new configuration"
    NEEDS_UPDATE=1
  else
    CURRENT_ENABLED=$(defaults read "@plistPath@" NAT -dict 2>/dev/null | grep -o 'Enabled = [01]' | cut -d' ' -f3 || echo "")
    if [ "$CURRENT_ENABLED" != "@desiredEnabled@" ]; then
      echo "[internetSharing] enabled state differs (current=$CURRENT_ENABLED, desired=@desiredEnabled@)"
      NEEDS_UPDATE=1
    fi

    CURRENT_IFACE=$(defaults read "@plistPath@" NAT -dict 2>/dev/null | grep -o 'PrimaryInterface = "[^"]*"' | cut -d'"' -f2 || echo "")
    if [ "$CURRENT_IFACE" != "@primaryInterface@" ]; then
      echo "[internetSharing] primary interface differs (current=$CURRENT_IFACE, desired=@primaryInterface@)"
      NEEDS_UPDATE=1
    fi

    CURRENT_DEVICES=$(defaults read "@plistPath@" NAT -dict 2>/dev/null | grep -A10 'SharingDevices' | grep -o 'bridge[0-9]*' | sort | tr '\n' ',' || echo "")
    DESIRED_DEVICES="@desiredDevices@"
    if [ "$CURRENT_DEVICES" != "$DESIRED_DEVICES," ]; then
      echo "[internetSharing] sharing devices differ (current=$CURRENT_DEVICES, desired=$DESIRED_DEVICES)"
      NEEDS_UPDATE=1
    fi
  fi

  if [ $NEEDS_UPDATE -eq 0 ]; then
    echo "[internetSharing] configuration already matches desired state"
    echo "[internetSharing] end $(date)"
    exit 0
  fi

  echo "[internetSharing] writing new configuration"

  defaults delete "@plistPath@" NAT 2>/dev/null || true

  defaults write "@plistPath@" NAT -dict-add Enabled -bool @enableFlag@
  defaults write "@plistPath@" NAT -dict-add PrimaryInterface -string "@primaryInterface@"

  /usr/libexec/PlistBuddy -c "Delete :NAT:SharingDevices" "@plistPath@" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :NAT:SharingDevices array" "@plistPath@"
  @sharingDevicesCmds@

  echo "[internetSharing] configuration written:"
  defaults read "@plistPath@" NAT

  @autoToggleBlock@

  echo "[internetSharing] end $(date)"
}

activation_run darwin.activationScripts.networking.internet-sharing-configure main "$@"
