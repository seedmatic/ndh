#!/usr/bin/env bash
# lima-network-namer.sh (@codebase)
# Network naming utility for Lima configurations
# Determines appropriate network names based on host configuration
#
# Usage:
#   ./bin/lima-network-namer.sh --host bioskop --type bridged
#   ./bin/lima-network-namer.sh --host bioskop --type shared
#
set -euo pipefail

# Default values
HOST=""
TYPE=""
LIST_ALL=0

usage() {
    cat << 'EOF'
Usage: lima-network-namer.sh [OPTIONS]

Generate consistent Lima network names using simple, direct naming.

Options:
  --host NAME           Host name (for informational purposes)
  --type TYPE           Network type: bridged, shared, host
  --list-all           List all possible network names for the host
  --help               Show this help

Network Naming Convention:
  Direct network names based on function:
    - bridged         (VM direct LAN access via host bridge)
    - host           (Direct host networking mode)
    - shared         (NAT/shared networking with gateway)
    
  The network name matches the Lima 'mode' for clarity.

Examples:
  # Get bridged network name (works for any host)
  lima-network-namer.sh --host bioskop --type bridged
  # Output: bridged

  # Get shared network name
  lima-network-namer.sh --host bioskop --type shared
  # Output: shared

  # Get host network name
  lima-network-namer.sh --host bioskop --type host
  # Output: host

  # List all networks for a host
  lima-network-namer.sh --host bioskop --list-all
EOF
}

# Host configuration mapping
declare -A HOST_BOND_CONFIG=(
    ["bioskop"]="bond"     # Uses bond0 (en0 + en8)
    ["default"]="single"   # Default: single interface setup
)

declare -A HOST_PRIMARY_INTERFACE=(
    ["bioskop"]="bond0"    # Primary interface for bioskop
    ["default"]="en0"      # Default primary interface
)

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --host)
            HOST="$2"; shift 2 ;;
        --type)
            TYPE="$2"; shift 2 ;;
        --list-all)
            LIST_ALL=1; shift ;;
        --help)
            usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# Validation
if [[ -z "$HOST" ]]; then
    echo "Error: --host is required" >&2
    usage; exit 1
fi

if [[ $LIST_ALL -eq 0 && -z "$TYPE" ]]; then
    echo "Error: --type is required (unless using --list-all)" >&2
    usage; exit 1
fi

# Helper functions
get_interface_type() {
    local host="$1"
    echo "${HOST_BOND_CONFIG[$host]:-${HOST_BOND_CONFIG[default]}}"
}

get_primary_interface() {
    local host="$1"
    echo "${HOST_PRIMARY_INTERFACE[$host]:-${HOST_PRIMARY_INTERFACE[default]}}"
}

generate_bridged_name() {
    echo "bridged"
}

generate_shared_name() {
    echo "shared"
}

generate_host_name() {
    echo "host"
}

list_all_networks() {
    local host="$1"
    echo "Available networks for host '$host':"
    echo ""
    echo "Network types:"
    echo "  bridged    - VM gets direct LAN access via $(get_primary_interface "$host")"
    echo "  shared     - VM uses NAT/shared networking with gateway"
    echo "  host       - VM shares host networking directly"
    echo ""
    echo "Host configuration:"
    echo "  Interface type: $(get_interface_type "$host")"
    echo "  Primary interface: $(get_primary_interface "$host")"
}

# Main execution
if [[ $LIST_ALL -eq 1 ]]; then
    list_all_networks "$HOST"
    exit 0
fi

case "$TYPE" in
    "bridged")
        generate_bridged_name
        ;;
    "shared")
        generate_shared_name
        ;;
    "host")
        generate_host_name
        ;;
    *)
        echo "Error: Invalid type '$TYPE'. Must be: bridged, shared, host" >&2
        exit 1
        ;;
esac