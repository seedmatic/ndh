#!/usr/bin/env bash
# lima-network-diagnostics.sh (@codebase)
# Collect host + Lima VM network state to verify deterministic subnet allocation
# and socket_vmnet parameters (gateway/subnet/mask/dhcp range).
#
# Usage:
#   ./bin/lima-network-diagnostics.sh                  # default instance nerd-nixos
#   ./bin/lima-network-diagnostics.sh --instance NAME  # specify Lima instance
#   ./bin/lima-network-diagnostics.sh --json           # write JSON summary to diagnostics/lima-network.json
#   ./bin/lima-network-diagnostics.sh --quiet          # suppress verbose sections (only summary)
#
# Requirements: bash, grep, awk, sed. Optional: limactl, yq-go, jq.
#
# Output:
#   - Human readable report on stdout
#   - Optional JSON summary (subnet, gateway, vm IPs, routes) if --json passed
#
set -euo pipefail
IFS=$'\n\t'

INSTANCE="nerd-nixos"
WRITE_JSON=0
QUIET=0
REPORT_DIR="diagnostics"

while (( "$#" )); do
  case "$1" in
    --instance|-i) INSTANCE="$2"; shift 2;;
    --json) WRITE_JSON=1; shift;;
    --quiet|-q) QUIET=1; shift;;
    --help|-h)
      sed -n '1,40p' "$0" | grep -v '^#!/' # show header
      exit 0
      ;;
    *) echo "[ERROR] Unknown arg: $1" >&2; exit 1;;
  esac
done

log() { [ "$QUIET" -eq 0 ] && echo "$*"; }

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[WARN] Missing dependency: $1" >&2
    return 1
  fi
}

JSON_ESCAPE() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

HOSTNAME=$(hostname -s || hostname)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Attempt to locate Lima instance directory
LIMA_HOME="${HOME}/.lima/${INSTANCE}"
if [ ! -d "$LIMA_HOME" ]; then
  echo "[ERROR] Lima instance directory not found: $LIMA_HOME" >&2
fi

YAML_PATH="$LIMA_HOME/lima.yaml"
JSON_PATH="$LIMA_HOME/lima.yaml.json"

log "=== Lima Network Diagnostics (@codebase) ==="
log "Timestamp: $TS"
log "Host: $HOSTNAME"
log "Instance: $INSTANCE"

if [ -f "$YAML_PATH" ]; then
  log "Found lima.yaml: $YAML_PATH (size $(wc -c < "$YAML_PATH"))"
  if require grep; then
    log "Subnet lines (grep subnet/gateway/mask):"
    grep -E 'subnet|gateway|mask|dhcpEnd' "$YAML_PATH" || true
  fi
elif [ -f "$JSON_PATH" ]; then
  log "Found JSON fallback: $JSON_PATH (size $(wc -c < "$JSON_PATH"))"
  grep -E 'subnet|gateway|mask|dhcpEnd' "$JSON_PATH" || true
else
  echo "[WARN] lima.yaml not present; activation may not have run yet." >&2
fi

# Extract socket_vmnet parameters via yq-go or fallback grep
SOCKET_SUBNET=""
SOCKET_GATEWAY=""
SOCKET_DHCPEND=""
if [ -f "$YAML_PATH" ] && command -v yq-go >/dev/null 2>&1; then
  SOCKET_SUBNET=$(yq-go '.networks[] | select(.socketVMNet.subnet != null) | .socketVMNet.subnet' "$YAML_PATH" 2>/dev/null || true)
  SOCKET_GATEWAY=$(yq-go '.networks[] | select(.socketVMNet.gateway != null) | .socketVMNet.gateway' "$YAML_PATH" 2>/dev/null || true)
  SOCKET_DHCPEND=$(yq-go '.networks[] | select(.socketVMNet.dhcpEnd != null) | .socketVMNet.dhcpEnd' "$YAML_PATH" 2>/dev/null || true)
fi
if [ -z "$SOCKET_SUBNET" ] && [ -f "$YAML_PATH" ]; then
  SOCKET_SUBNET=$(grep -E 'subnet:' "$YAML_PATH" | head -1 | awk '{print $2}') || true
  SOCKET_GATEWAY=$(grep -E 'gateway:' "$YAML_PATH" | head -1 | awk '{print $2}') || true
  SOCKET_DHCPEND=$(grep -E 'dhcpEnd:' "$YAML_PATH" | head -1 | awk '{print $2}') || true
fi

log "Derived socket_vmnet: subnet=$SOCKET_SUBNET gateway=$SOCKET_GATEWAY dhcpEnd=$SOCKET_DHCPEND"

# Host processes: look for socket_vmnet
log "-- Host socket_vmnet processes --"
(ps -axo pid,command | grep -E 'socket_vmnet' | grep -v grep) || log "(none)"

# Host interface snapshots
log "-- Host interface summary --"
for IF in vznat0 vmlan0 vmwan0; do
  if ifconfig "$IF" >/dev/null 2>&1; then
    ADDR=$(ifconfig "$IF" | awk '/inet /{print $2}' | head -1)
    MAC=$(ifconfig "$IF" | awk '/ether/{print $2}' | head -1)
    log "$IF: ip=$ADDR mac=$MAC"
  fi
done

log "-- Host routing table (filtered 10.80/172.16) --"
(netstat -rn | grep -E '(^Destination|10\.80|172\.16)' ) || true

VM_IP_WAN=""
VM_IP_NAT=""
ROUTES_VM=""
RESOLV_VM=""

if command -v limactl >/dev/null 2>&1; then
  if limactl list | grep -q "^${INSTANCE}\b"; then
    log "-- Querying VM via limactl shell --"
    VM_IP_WAN=$(limactl shell "$INSTANCE" bash -c "ip -4 addr show dev vmwan0 2>/dev/null | awk '/inet /{print \$2}'" || true)
    VM_IP_NAT=$(limactl shell "$INSTANCE" bash -c "ip -4 addr show dev vznat0 2>/dev/null | awk '/inet /{print \$2}'" || true)
    ROUTES_VM=$(limactl shell "$INSTANCE" bash -c "ip -4 route show" || true)
    RESOLV_VM=$(limactl shell "$INSTANCE" bash -c "cat /etc/resolv.conf" || true)
    log "VM vmwan0 IPv4: $VM_IP_WAN"
    log "VM vznat0 IPv4: $VM_IP_NAT"
  else
    echo "[WARN] Lima instance '$INSTANCE' not running (limactl list)." >&2
  fi
else
  echo "[WARN] limactl not installed; skipping in-VM inspection." >&2
fi

# JSON summary
if [ "$WRITE_JSON" -eq 1 ]; then
  mkdir -p "$REPORT_DIR"
  JSON_FILE="$REPORT_DIR/lima-network.json"
  cat > "$JSON_FILE" <<EOF
{
  "timestamp": "$(JSON_ESCAPE "$TS")",
  "host": "$(JSON_ESCAPE "$HOSTNAME")",
  "instance": "$(JSON_ESCAPE "$INSTANCE")",
  "socketVMNet": {
    "subnet": "$(JSON_ESCAPE "$SOCKET_SUBNET")",
    "gateway": "$(JSON_ESCAPE "$SOCKET_GATEWAY")",
    "dhcpEnd": "$(JSON_ESCAPE "$SOCKET_DHCPEND")"
  },
  "hostIfaces": {
    "vmwan0": {
      "ip": "$(JSON_ESCAPE $(ifconfig vmwan0 2>/dev/null | awk '/inet /{print $2}' | head -1 || true))",
      "mac": "$(JSON_ESCAPE $(ifconfig vmwan0 2>/dev/null | awk '/ether/{print $2}' | head -1 || true))"
    },
    "vznat0": {
      "ip": "$(JSON_ESCAPE $(ifconfig vznat0 2>/dev/null | awk '/inet /{print $2}' | head -1 || true))",
      "mac": "$(JSON_ESCAPE $(ifconfig vznat0 2>/dev/null | awk '/ether/{print $2}' | head -1 || true))"
    },
    "vmlan0": {
      "ip": "$(JSON_ESCAPE $(ifconfig vmlan0 2>/dev/null | awk '/inet /{print $2}' | head -1 || true))",
      "mac": "$(JSON_ESCAPE $(ifconfig vmlan0 2>/dev/null | awk '/ether/{print $2}' | head -1 || true))"
    }
  },
  "vm": {
    "vmwan0": "$(JSON_ESCAPE "$VM_IP_WAN")",
    "vznat0": "$(JSON_ESCAPE "$VM_IP_NAT")"
  },
  "vmRoutes": "$(JSON_ESCAPE "$ROUTES_VM")",
  "vmResolvConf": "$(JSON_ESCAPE "$RESOLV_VM")"
}
EOF
  log "Wrote JSON summary: $JSON_FILE"
fi

log "=== End diagnostics ==="
