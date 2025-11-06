#!/usr/bin/env bash
#
# Test aggregate bandwidth by running speedtest on both interfaces simultaneously
#

echo "=== Dual Interface Speedtest ==="
echo ""
echo "This will run speedtest on en0 and en8 simultaneously"
echo "to measure the aggregate bandwidth of your connection."
echo ""

# Create temporary files for results
RESULTS_EN0=$(mktemp)
RESULTS_EN8=$(mktemp)

echo "Starting speedtest on en0 (built-in Ethernet) -> Networth Telecom (Clichy)..."
speedtest --interface=en0 --server-id=28073 --accept-license --accept-gdpr --format=json > "$RESULTS_EN0" 2>&1 &
PID_EN0=$!

echo "Starting speedtest on en8 (OWC hub Ethernet) -> KEYYO (Paris)..."
speedtest --interface=en8 --server-id=27961 --accept-license --accept-gdpr --format=json > "$RESULTS_EN8" 2>&1 &
PID_EN8=$!

echo ""
echo "Running tests in parallel..."
echo "This may take 30-60 seconds..."
echo ""

# Wait for both to complete
wait $PID_EN0
wait $PID_EN8

echo "=== Results ==="
echo ""
echo "--- en0 (Built-in Ethernet) ---"
if command -v jq >/dev/null 2>&1; then
    cat "$RESULTS_EN0" | jq -r '"Server: \(.server.name) - \(.server.location) (id: \(.server.id))\nDownload: \(.download.bandwidth / 125000 | floor) Mbps\nUpload: \(.upload.bandwidth / 125000 | floor) Mbps\nPing: \(.ping.latency) ms"' 2>/dev/null || cat "$RESULTS_EN0"
else
    cat "$RESULTS_EN0"
fi

echo ""
echo "--- en8 (OWC Hub Ethernet) ---"
if command -v jq >/dev/null 2>&1; then
    cat "$RESULTS_EN8" | jq -r '"Server: \(.server.name) - \(.server.location) (id: \(.server.id))\nDownload: \(.download.bandwidth / 125000 | floor) Mbps\nUpload: \(.upload.bandwidth / 125000 | floor) Mbps\nPing: \(.ping.latency) ms"' 2>/dev/null || cat "$RESULTS_EN8"
else
    cat "$RESULTS_EN8"
fi

echo ""
echo "=== Aggregate Calculation ==="

# Extract download speeds from JSON (bandwidth is in bytes/sec, divide by 125000 for Mbps)
if command -v jq >/dev/null 2>&1; then
    DL_EN0=$(cat "$RESULTS_EN0" | jq -r '.download.bandwidth / 125000' 2>/dev/null)
    DL_EN8=$(cat "$RESULTS_EN8" | jq -r '.download.bandwidth / 125000' 2>/dev/null)
    UL_EN0=$(cat "$RESULTS_EN0" | jq -r '.upload.bandwidth / 125000' 2>/dev/null)
    UL_EN8=$(cat "$RESULTS_EN8" | jq -r '.upload.bandwidth / 125000' 2>/dev/null)
else
    # Fallback to grep if jq not available
    DL_EN0=$(grep "Download:" "$RESULTS_EN0" | awk '{print $2}' | sed 's/[^0-9.]//g')
    DL_EN8=$(grep "Download:" "$RESULTS_EN8" | awk '{print $2}' | sed 's/[^0-9.]//g')
    UL_EN0=$(grep "Upload:" "$RESULTS_EN0" | awk '{print $2}' | sed 's/[^0-9.]//g')
    UL_EN8=$(grep "Upload:" "$RESULTS_EN8" | awk '{print $2}' | sed 's/[^0-9.]//g')
fi

if [ -n "$DL_EN0" ] && [ -n "$DL_EN8" ]; then
    TOTAL_DL=$(echo "$DL_EN0 + $DL_EN8" | bc)
    echo "Total Download: ${TOTAL_DL} Mbps (en0: ${DL_EN0} + en8: ${DL_EN8})"
else
    echo "Could not calculate total download (one or both tests failed)"
fi

if [ -n "$UL_EN0" ] && [ -n "$UL_EN8" ]; then
    TOTAL_UL=$(echo "$UL_EN0 + $UL_EN8" | bc)
    echo "Total Upload:   ${TOTAL_UL} Mbps (en0: ${UL_EN0} + en8: ${UL_EN8})"
else
    echo "Could not calculate total upload (one or both tests failed)"
fi

echo ""
echo "=== Analysis ==="
if [ -n "$TOTAL_DL" ] && [ -n "$TOTAL_UL" ]; then
    if (( $(echo "$TOTAL_DL > 1500" | bc -l) )); then
        echo "✅ Your connection supports >1.5 Gbps aggregate download!"
        echo "   Link aggregation with LACP would be beneficial if your switch supported it."
    elif (( $(echo "$TOTAL_DL > 1000" | bc -l) )); then
        echo "⚠️  Aggregate download is ~${TOTAL_DL} Mbps (>1 Gbps but <1.5 Gbps)"
        echo "   Your ISP connection or switch may be limiting aggregate throughput."
    else
        echo "ℹ️  Aggregate download is ~${TOTAL_DL} Mbps (≤1 Gbps)"
        echo "   Your ISP connection appears limited to ~1 Gbps total."
        echo "   Bonding won't provide additional bandwidth."
    fi
fi

# Cleanup
rm -f "$RESULTS_EN0" "$RESULTS_EN8"

echo ""
echo "=== Test Complete ==="
