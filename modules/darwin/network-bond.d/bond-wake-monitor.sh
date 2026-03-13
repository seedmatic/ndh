#!/usr/bin/env bash
exec > >(logger -t darwin-network-bond-wake) 2>&1

echo "[$(date)] Bond wake monitor started"

# Monitor kernel power management events for wake from sleep
# Filter for actual wake events using predicate to avoid false positives
log stream --level info --predicate 'subsystem == "com.apple.iokit.power" AND eventMessage CONTAINS "Wake from"' --style compact 2>/dev/null | \
while read -r line; do
  echo "[$(date)] System woke from sleep"
  
  # Wait for network interfaces to come up
  sleep 10
  
  # Check if bond0 exists and renew DHCP
  if ifconfig bond0 >/dev/null 2>&1; then
    echo "[$(date)] Renewing DHCP on bond0..."
    ipconfig set bond0 DHCP
    ipconfig set bond0 AUTOMATIC-V6
    sleep 3
    
    # Fix routing - remove WiFi default route only
    # NOTE (@codebase): preserve bridge* defaults for Lima compatibility.
    route -n delete default -ifscope en1 2>/dev/null || true
    
    # Log the result
    if ipconfig getifaddr bond0 >/dev/null 2>&1; then
      IP=$(ipconfig getifaddr bond0)
      echo "[$(date)] Bond0 IP: $IP"
    else
      echo "[$(date)] WARNING: bond0 did not get an IP address"
    fi
  else
    echo "[$(date)] WARNING: bond0 interface not found"
  fi
done
