#!/usr/bin/env bash
#
# Check if your router/switch (bbox) supports network bonding/LACP
#

echo "=== Checking Bonding/LACP Support on Router/Switch ==="
echo ""

echo "1. Checking LLDP neighbors..."
echo "   Starting lldpd daemon..."
sudo lldpd -d 2>&1 | grep -v WARN | head -5
sleep 10

echo ""
echo "   LLDP Neighbors detected:"
sudo lldpctl show neighbors

echo ""
echo "2. Checking for LACP/aggregation capabilities..."
sudo lldpctl -f keyvalue | grep -i "aggregation\|lacp\|capability" || echo "   No LACP/aggregation info advertised"

echo ""
echo "3. Router/Switch Information:"
echo "   Both en0 and en8 are connected to the same switch port:"
sudo lldpctl -f keyvalue | grep "port.mac" | sort -u

echo ""
echo "4. Recommendations:"
echo ""

# Check if LACP is advertised
if sudo lldpctl -f keyvalue | grep -qi "lacp\|aggregation"; then
    echo "   ✅ Your switch advertises LACP support!"
    echo "   → You can use LACP mode (802.3ad) for bonding"
    echo "   → Run: ./bin/setup-network-bond.sh"
else
    echo "   ⚠️  Your switch doesn't advertise LACP capabilities via LLDP"
    echo ""
    echo "   This could mean:"
    echo "   a) The switch doesn't support LACP (most consumer routers don't)"
    echo "   b) LACP support is not advertised via LLDP"
    echo ""
    echo "   Options:"
    echo "   1. Check your bbox admin interface at http://192.168.1.254"
    echo "      Look for: Link Aggregation, Port Trunking, or LACP settings"
    echo ""
    echo "   2. Try bonding anyway with fallback mode:"
    echo "      - Modify setup-network-bond.sh to use 'bondmode 0' (round-robin)"
    echo "      - This doesn't require switch support"
    echo "      - May work but not optimal"
    echo ""
    echo "   3. Alternative: Use both interfaces separately"
    echo "      - Keep en0 for primary traffic"
    echo "      - Route specific traffic through en8"
fi

echo ""
echo "5. To access your bbox admin interface:"
echo "   URL: http://192.168.1.254"
echo "   Check for Link Aggregation or LACP settings"
echo ""

# Cleanup
sudo pkill lldpd 2>/dev/null

echo "=== Check Complete ==="
