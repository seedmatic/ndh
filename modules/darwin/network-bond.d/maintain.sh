#!/usr/bin/env bash
exec > >(logger -t darwin-network-bond-maintain) 2>&1

set -x  # Enable trace mode for debugging
echo "[$(date)] Network state changed, checking bond configuration..."

# Check if bond0 exists
if ! ifconfig bond0 >/dev/null 2>&1; then
  echo "[$(date)] bond0 does not exist, exiting"
  exit 0
fi

# Check if bond0 has an IP, if not restore it
if ! ipconfig getifaddr bond0 >/dev/null 2>&1; then
  echo "[$(date)] bond0 has no IP, restoring DHCP..."
  ipconfig set bond0 DHCP
  ipconfig set bond0 AUTOMATIC-V6
  sleep 3
fi

# Clear any IPs on member interfaces
@clearMemberIps@

# Ensure WiFi doesn't have the primary default route
# Set network service order: bond members (Ethernet, USB LAN) before WiFi
echo "[$(date)] Setting network service order: bond members > WiFi"

# Get ALL network services (including disabled ones, but strip asterisks)
SERVICES=$(networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//')

# Build ordered list: bond members first, then others, WiFi last
declare -a ORDERED_ARRAY
WIFI_SERVICE=""

# First pass: collect bond members
while IFS= read -r service; do
  [ -z "$service" ] && continue
  case "$service" in
    *"Ethernet"*|*"USB"*"LAN"*)
      ORDERED_ARRAY+=("$service")
      ;;
  esac
done <<< "$SERVICES"

# Second pass: collect non-WiFi, non-bond services
while IFS= read -r service; do
  [ -z "$service" ] && continue
  case "$service" in
    *"Ethernet"*|*"USB"*"LAN"*|*"Wi-Fi"*)
      # Skip - already handled or will be last
      if [[ "$service" == *"Wi-Fi"* ]]; then
        WIFI_SERVICE="$service"
      fi
      ;;
    *)
      ORDERED_ARRAY+=("$service")
      ;;
  esac
done <<< "$SERVICES"

# Add WiFi last
if [ -n "$WIFI_SERVICE" ]; then
  ORDERED_ARRAY+=("$WIFI_SERVICE")
fi

# Apply new order if WiFi was found and reordering needed
if [ -n "$WIFI_SERVICE" ] && [ "${#ORDERED_ARRAY[@]}" -gt 0 ]; then
  echo "[$(date)] New service order: ${ORDERED_ARRAY[*]}"
  networksetup -ordernetworkservices "${ORDERED_ARRAY[@]}" || true
  
  # Ensure bond0 route has higher priority than WiFi when bond0 is available
  if ipconfig getifaddr bond0 >/dev/null 2>&1; then
    BOND_GATEWAY=$(route -n get default -ifscope bond0 2>/dev/null | awk '/gateway:/ {print $2}' || echo "192.168.1.254")
    if [ -n "$BOND_GATEWAY" ] && [ "$BOND_GATEWAY" != "" ]; then
      echo "[$(date)] Adding priority default route via bond0 ($BOND_GATEWAY)"
      # Add a more specific route that takes precedence over WiFi default route
      route -n add default "$BOND_GATEWAY" -ifscope bond0 || true
    fi
  fi
fi

# Remove default routes from Lima bridge interfaces (bridge100, bridge101, etc.)
for bridge in $(ifconfig -l | tr ' ' '\n' | grep '^bridge'); do
  if netstat -rn | grep -q "^default.*$bridge"; then
    echo "[$(date)] Lima bridge $bridge has default route, removing..."
    route -n delete default -ifscope "$bridge" 2>/dev/null || true
  fi
done

echo "[$(date)] Bond maintenance complete"
