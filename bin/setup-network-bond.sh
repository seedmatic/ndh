#!/usr/bin/env bash
#
# Setup network bonding between en0 (Mac mini built-in) and en8 (OWC hub)
# This will combine both Gigabit Ethernet interfaces for aggregate bandwidth
# using Round-Robin mode (no switch support needed)
#
# WARNING: This will temporarily disrupt network connectivity!
# Make sure you're working locally at the Mac mini console.

set -e

echo "=== Network Bond Setup Script ==="
echo ""
echo "This script will:"
echo "  1. Create a bond interface (bond0)"
echo "  2. Add en0 (built-in Ethernet) to the bond"
echo "  3. Add en8 (USB Ethernet from OWC hub) to the bond"
echo "  4. Configure bond0 with DHCP"
echo ""
echo "WARNING: Network connectivity will be interrupted during setup!"
echo ""
read -p "Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "Step 1: Checking current bond status..."
networksetup -listbonds

echo ""
echo "Step 2: Checking current interface configuration..."
echo "en0:"
ifconfig en0 | grep -E "inet |status"
echo "en8:"
ifconfig en8 | grep -E "inet |status"

echo ""
echo "Step 3: Releasing DHCP leases on en0 and en8..."
sudo ipconfig set en0 NONE
sudo ipconfig set en8 NONE

echo ""
echo "Step 4: Bringing down individual interfaces..."
sudo ifconfig en0 down
sudo ifconfig en8 down

echo ""
echo "Step 5: Creating bond interface..."
sudo ifconfig bond0 create 2>/dev/null || echo "bond0 already exists"

echo ""
echo "Step 6: Adding en0 to bond..."
sudo ifconfig bond0 bonddev en0

echo ""
echo "Step 7: Adding en8 to bond..."
sudo ifconfig bond0 bonddev en8

echo ""
echo "Step 8: Setting bond mode to Round-Robin (mode 0)..."
sudo ifconfig bond0 bondmode 0

echo ""
echo "Step 9: Bringing bond interface up..."
sudo ifconfig bond0 up

echo ""
echo "Step 10: Configuring DHCP on bond..."
# Need to use networksetup, but it requires a service name
# First, check if "Link Aggregate" service exists
if networksetup -listallnetworkservices | grep -q "Link Aggregate"; then
    sudo networksetup -setDHCP "Link Aggregate"
else
    echo "Creating network service for bond..."
    sudo networksetup -createnetworkservice "Link Aggregate" bond0
    sudo networksetup -setDHCP "Link Aggregate"
fi

echo ""
echo "Step 11: Checking bond status..."
ifconfig bond0
networksetup -listbonds

echo ""
echo "Step 12: Waiting for DHCP..."
sleep 5

echo ""
echo "Step 13: Checking IP configuration..."
ifconfig bond0 | grep -E "inet |ether |status"

echo ""
echo "=== Bond Setup Complete ==="
echo ""
echo "To test throughput, run:"
echo "  speedtest --interface=bond0"
echo ""
echo "To remove the bond later, run:"
echo "  sudo ifconfig bond0 -bonddev en0"
echo "  sudo ifconfig bond0 -bonddev en8"
echo "  sudo ifconfig bond0 destroy"
echo "  sudo networksetup -removenetworkservice 'Link Aggregate'"
echo "  sudo ifconfig en0 up"
echo "  sudo ifconfig en8 up"
echo "  sudo ipconfig set en0 DHCP"
echo "  sudo ipconfig set en8 DHCP"
echo ""
