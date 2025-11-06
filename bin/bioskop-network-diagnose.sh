#!/usr/bin/env bash
# bioskop-network-diagnose.sh (@codebase)
# Purpose: Diagnose why packets (e.g. ICMP from 10.80.x containers) seen on bridge101
# are not forwarded/NATed out via the primary uplink (e.g. en0).
# Run on the Darwin host (bioskop). No changes performed; read-only except optional suggestion block.
set -euo pipefail

echo "[1/10] Interface summary (bridge + potential uplink)"
ifconfig bridge101 || echo "bridge101: not found"
# Try common uplink names
for IF in en0 en1 enp0s1; do
  if ifconfig "$IF" >/dev/null 2>&1; then
    echo "--- $IF ---"
    ifconfig "$IF" | sed -n '1,15p'
  fi
done

echo "[2/10] IP forwarding state"
sysctl net.inet.ip.forwarding || true

echo "[3/10] Routing table (10.80.* + default)"
netstat -rn | egrep '10\.80\.|default' || true

echo "[4/10] PF status & NAT summary"
PF_ENABLED=$(sudo pfctl -s info 2>/dev/null | awk '/Status:/ {print $2}') || PF_ENABLED=unknown
echo "PF Status: $PF_ENABLED"
echo "-- NAT rules (filtered 10.80) --"
sudo pfctl -sn 2>/dev/null | egrep '10\.80\.' || echo "(no 10.80.* NAT rules)"

echo "[5/10] PF filter rules referencing 10.80.* (may be blocking)"
sudo pfctl -sr 2>/dev/null | egrep '10\.80\.' || echo "(no explicit 10.80.* filter rules)"
echo "-- Anchor rke2.rancher ruleset (summary) --"
sudo pfctl -a rke2.rancher -sr 2>/dev/null || echo "(anchor rke2.rancher not found)"
echo "-- Anchor rke2.rancher NAT --"
sudo pfctl -a rke2.rancher -sn 2>/dev/null || echo "(no NAT in rke2.rancher)"
echo "-- Rule counters (look for increasing states) --"
sudo pfctl -a rke2.rancher -v -sr 2>/dev/null | egrep '10\.80\.' || echo "(no counters yet)"

echo "[6/10] ARP entries for 10.80.* (gateway presence)"
arp -a | egrep '10\.80\.' || echo "(no ARP entries for 10.80.*)"

echo "[7/10] Bridge membership and STP"
ifconfig bridge101 2>/dev/null | egrep 'member|stp' || echo "(no member lines or STP disabled)"

echo "[8/10] Live capture attempt (5 packets) - requires admin"
UPLINK="en0"
if ifconfig en0 >/dev/null 2>&1; then UPLINK=en0; fi
if ifconfig enp0s1 >/dev/null 2>&1; then UPLINK=enp0s1; fi
# Only print command to avoid hanging script if run non-interactively
echo "Run manually (in another terminal if needed): sudo tcpdump -ni $UPLINK src net 10.80.16.0/24 -c 5"

echo "[9/10] Suggested pf NAT lines (NOT applied)"
cat <<'EOF'
# Add to /etc/pf.conf (after existing anchors)
# Example assuming en0 is uplink; adjust if different
nat on en0 from 10.80.16.0/24 to any -> (en0)
# If VIP subnet used:
nat on en0 from 10.80.31.0/24 to any -> (en0)
EOF

echo "[10/10] Gateway IP suggestion"
cat <<'EOF'
# If bridge101 lacks an IP acting as container default gateway:
sudo ifconfig bridge101 inet 10.80.16.1/24 alias
# Then inside container:
#   ip route replace default via 10.80.16.1
# Enable forwarding (temporary):
#   sudo sysctl -w net.inet.ip.forwarding=1
EOF

echo "--- Summary Heuristics ---"
# Heuristic conclusions based on absence conditions
HAS_NAT=$(sudo pfctl -sn 2>/dev/null | egrep -c '10\.80\.')
if [ "$HAS_NAT" -eq 0 ]; then
  echo "No NAT rules for 10.80.*: packets will leave (if forwarded) with private source and be dropped upstream."
fi
# Check for ICMP pass rules (needed for ping)
HAS_ICMP_PASS=$(sudo pfctl -a rke2.rancher -sr 2>/dev/null | egrep -c 'proto icmp') || HAS_ICMP_PASS=0
if [ "$HAS_ICMP_PASS" -eq 0 ]; then
  echo "Missing explicit ICMP pass rule in rke2.rancher anchor: ping may fail. Add: 'pass out on en0 inet proto icmp from <rke2_subnets> to any keep state'" 
fi
# Check for generic pass out rule without tcp-only flags
GENERIC_PASS=$(sudo pfctl -a rke2.rancher -sr 2>/dev/null | egrep -c 'pass out on en0 inet from <rke2_subnets> to any') || GENERIC_PASS=0
if [ "$GENERIC_PASS" -eq 0 ]; then
  echo "No generic outbound pass rule for <rke2_subnets>. Add: 'pass out on en0 inet from <rke2_subnets> to any keep state'" 
fi
GW_PRESENT=$(arp -a | egrep -c '10\.80\.16\.1') || GW_PRESENT=0
if [ "$GW_PRESENT" -eq 0 ]; then
  echo "No ARP/gateway 10.80.16.1: container default route to that IP will fail; host not acting as router." 
fi
FWD=$(sysctl -n net.inet.ip.forwarding || echo 0)
if [ "$FWD" -eq 0 ]; then
  echo "IP forwarding disabled: even with gateway + NAT, packets won't traverse host." 
fi

echo "Diagnostics complete. Review above for missing: (1) bridge gateway IP, (2) forwarding, (3) pf NAT rules."