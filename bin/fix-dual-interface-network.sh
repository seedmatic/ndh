#!/usr/bin/env bash
# Fix multiple network interface issues on the same LAN
# Handles Ethernet (en0), Wi-Fi (en1), and USB Ethernet (en8) conflicts

set -euo pipefail

echo "=== Multiple Interface Network Fix ==="
echo ""

# Configuration - Priority order (highest to lowest)
PRIMARY_IFACE="en0"    # Built-in Ethernet (highest priority)
WIFI_IFACE="en1"       # Wi-Fi (backup when wired unavailable)  
USB_IFACE="en8"        # USB Ethernet (lowest priority)

echo "Interface Priority Order:"
echo "  1. $PRIMARY_IFACE (Built-in Ethernet - primary)"
echo "  2. $WIFI_IFACE (Wi-Fi - backup)"
echo "  3. $USB_IFACE (USB Ethernet - disabled)"
echo ""

echo "Step 1: Check interface status..."
for IFACE in "$PRIMARY_IFACE" "$WIFI_IFACE" "$USB_IFACE"; do
    if ifconfig "$IFACE" >/dev/null 2>&1; then
        STATUS=$(ifconfig "$IFACE" | grep "status:" | awk '{print $2}')
        IP=$(ifconfig "$IFACE" | grep "inet " | awk '{print $2}' | head -1)
        echo "  $IFACE: $STATUS${IP:+ - $IP}"
    else
        echo "  $IFACE: not found"
    fi
done

echo ""
echo "Step 2: Remove conflicting default routes..."
# Remove default routes from secondary interfaces
for IFACE in "$WIFI_IFACE" "$USB_IFACE"; do
    if netstat -rn | grep "^default" | grep -q "$IFACE"; then
        echo "  Removing default route from $IFACE"
        sudo route -n delete default -ifscope "$IFACE" 2>/dev/null || true
    fi
done

echo ""
echo "Step 3: Configure network service priority..."
# Set network service order: Ethernet > Wi-Fi > USB Ethernet
echo "  Setting service priority order..."
sudo networksetup -ordernetworkservices \
    "Ethernet" \
    "Wi-Fi" \
    "USB 10/100/1000 LAN" \
    "Display Ethernet" 2>/dev/null || true

echo ""
echo "Step 4: Configure interface roles..."

# Disable USB Ethernet completely (lowest priority)
echo "  Disabling USB Ethernet ($USB_IFACE)..."
sudo ifconfig "$USB_IFACE" down 2>/dev/null || true
sudo ipconfig set "$USB_IFACE" NONE 2>/dev/null || true

# Configure Wi-Fi as backup (remove default route but keep IP)
echo "  Configuring Wi-Fi ($WIFI_IFACE) as backup only..."
if ifconfig "$WIFI_IFACE" | grep -q "status: active"; then
    # Remove Wi-Fi default route but keep the IP for backup purposes
    sudo route -n delete default -ifscope "$WIFI_IFACE" 2>/dev/null || true
    
    # Add a higher-metric route for Wi-Fi (backup route)
    GATEWAY=$(netstat -rn | grep "^default.*$PRIMARY_IFACE" | awk '{print $2}' | head -1)
    if [ -n "$GATEWAY" ]; then
        sudo route -n add default "$GATEWAY" -ifscope "$WIFI_IFACE" -hopcount 10 2>/dev/null || true
    fi
fi

echo ""
echo "Step 5: Clean ARP cache to remove stale entries..."
sudo arp -d -a 2>/dev/null || true

echo ""
echo "Step 6: Ensure primary interface is properly configured..."
if ! ifconfig "$PRIMARY_IFACE" | grep -q "status: active"; then
    echo "  Bringing up primary interface ($PRIMARY_IFACE)..."
    sudo ifconfig "$PRIMARY_IFACE" up
    sudo ipconfig set "$PRIMARY_IFACE" DHCP
    sleep 3
fi

echo ""
echo "Step 7: Verification..."
echo "--- Interface Status ---"
for IFACE in "$PRIMARY_IFACE" "$WIFI_IFACE" "$USB_IFACE"; do
    if ifconfig "$IFACE" >/dev/null 2>&1; then
        STATUS=$(ifconfig "$IFACE" | grep "status:" | awk '{print $2}')
        IP=$(ifconfig "$IFACE" | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
        echo "$IFACE: $STATUS${IP:+ - $IP}"
    fi
done

echo ""
echo "--- Routing Table ---"
netstat -rn | grep -E "^default|192\.168\.1"

echo ""
echo "--- Network Services Order ---"
networksetup -listnetworkserviceorder | head -10

echo ""
echo "=== Network Configuration Complete ==="
echo ""
echo "Interface Priority Configuration:"
echo "  • $PRIMARY_IFACE (Ethernet): Primary with default route"
echo "  • $WIFI_IFACE (Wi-Fi): Backup with high-metric route"  
echo "  • $USB_IFACE (USB Ethernet): Disabled"
echo ""
echo "Failover Instructions:"
echo "If Ethernet fails, Wi-Fi will automatically take over."
echo "To manually enable USB Ethernet as last resort:"
echo "  sudo ifconfig $USB_IFACE up"
echo "  sudo ipconfig set $USB_IFACE DHCP"
echo ""
echo "To restore all interfaces (for troubleshooting):"
echo "  sudo ifconfig $WIFI_IFACE up"
echo "  sudo ifconfig $USB_IFACE up"
echo "  sudo ipconfig set $WIFI_IFACE DHCP"
echo "  sudo ipconfig set $USB_IFACE DHCP"
echo ""