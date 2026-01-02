#!/bin/bash
echo "[bond] Configuring network bond interface (triggered by: ${1:-boot})" >&2

# Wait for network interfaces to be available
sleep 5

# Check if all interfaces exist
@daemonInterfaceChecks@

# Check if bond already exists with correct configuration
if ifconfig bond0 >/dev/null 2>&1; then
  CURRENT_MEMBERS=$(ifconfig bond0 | awk '/bond interfaces:/ {for(i=3;i<=NF;i++) print $i}' | sort | tr '\n' ' ' | xargs)
  DESIRED_MEMBERS=$(printf '%s\n' @bondInterfaces@ | sort | tr '\n' ' ' | xargs)
  
  if [ "$CURRENT_MEMBERS" = "$DESIRED_MEMBERS" ]; then
    echo "[bond] Bond already configured correctly" >&2
    exit 0
  fi
  
  # Destroy existing bond if configuration differs
  echo "[bond] Reconfiguring bond..." >&2
@bondDetach@
  ifconfig bond0 destroy || true
fi

echo "[bond] Creating bond interface with mode @bondMode@" >&2

# Release DHCP leases on individual interfaces and disable auto-config
@releaseInterfaces@

# Create bond interface
ifconfig bond0 create || true

# Add interfaces to bond first (this should prevent them from getting IPs)
@bondAttach@

# Ensure member interfaces don't get IP addresses after bonding
@releaseInterfaces@

# Set bond mode
ifconfig bond0 bondmode @bondMode@

# Bring bond interface up
ifconfig bond0 up

# Configure DHCP on bond interface
@dhcpDaemonBlock@

echo "[bond] Bond interface configured successfully" >&2
