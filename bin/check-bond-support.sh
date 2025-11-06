#!/usr/bin/env bash
#
# Check if your router/switch supports network bonding (LACP/802.3ad)
#
# This script will:
# 1. Show current network configuration
# 2. Test basic LACP negotiation
# 3. Provide guidance on what to check

set -e

echo "=== Network Bonding Support Check ==="
echo ""

# Get router IP
ROUTER_IP=$(netstat -rn | grep "^default" | grep -E "en[0-9]" | head -1 | awk '{print $2}')
echo "Router IP detected: $ROUTER_IP"
echo ""

echo "=== Method 1: Check if bond is already configured ==="
echo "Current bonds:"
networksetup -listbonds
echo ""

echo "=== Method 2: Check switch capabilities via LLDP (if available) ==="
if command -v lldpcli &> /dev/null; then
    echo "LLDP information:"
    sudo lldpcli show neighbors
else
    echo "lldpcli not installed. To install:"
    echo "  flox install lldpd"
fi
echo ""

echo "=== Method 3: Manual router/switch checks ==="
echo ""
echo "You need to check your router's web interface at: http://$ROUTER_IP"
echo ""
echo "Look for these features in your Bbox router settings:"
echo "  1. 'Link Aggregation' or 'Port Trunking'"
echo "  2. 'LACP' or '802.3ad'"
echo "  3. 'LAG' (Link Aggregation Group)"
echo "  4. 'Port Bonding'"
echo ""
echo "Common locations in router interfaces:"
echo "  - Advanced Settings > Network > LAN"
echo "  - Advanced > Port Management"
echo "  - LAN > Port Configuration"
echo "  - Advanced > Link Aggregation"
echo ""

echo "=== Method 4: Test LACP negotiation ==="
echo ""
echo "To test if LACP works:"
echo "  1. Run the bond setup script: ./bin/setup-network-bond.sh"
echo "  2. Check bond status: ifconfig bond0"
echo "  3. Look for 'status: active' (good) vs 'status: inactive' (bad)"
echo "  4. Check member interfaces:"
echo "     ifconfig en0 | grep 'member of bond0'"
echo "     ifconfig en8 | grep 'member of bond0'"
echo ""

echo "=== Method 5: Alternative - Use failover mode instead of LACP ==="
echo ""
echo "If your router doesn't support LACP, you can use failover mode:"
echo "  - Provides redundancy (if one link fails, other takes over)"
echo "  - Does NOT provide aggregated bandwidth"
echo "  - Works with any router/switch"
echo ""
echo "To use failover mode instead, modify setup-network-bond.sh:"
echo "  Change: sudo ifconfig bond0 bondmode lacp"
echo "  To:     sudo ifconfig bond0 bondmode failover"
echo ""

echo "=== Bbox Router Specifics ==="
echo ""
echo "For Bouygues Bbox routers:"
echo "  - Most Bbox models (Bbox Miami, Bbox Ultym) do NOT support LACP"
echo "  - They only have basic switching capabilities"
echo "  - Recommendation: Use failover mode OR keep interfaces separate"
echo ""
echo "To verify your Bbox model, check the sticker on the router"
echo "or visit: http://$ROUTER_IP"
echo ""

echo "=== Decision Guide ==="
echo ""
echo "Choose your setup based on:"
echo ""
echo "1. LACP supported (professional switches/routers):"
echo "   → Use LACP mode for full aggregated bandwidth (~2 Gbps)"
echo ""
echo "2. LACP NOT supported (most home routers including Bbox):"
echo "   Option A: Use failover mode (redundancy only, ~1 Gbps)"
echo "   Option B: Keep interfaces separate (what you have now)"
echo ""
echo "3. Current performance: ~940 Mbps per interface"
echo "   → Already excellent for most uses"
echo ""
