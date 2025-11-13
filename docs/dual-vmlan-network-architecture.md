# Dual-vmlan Network Architecture

This document describes the dual-vmlan network architecture used for separating NixOS VM and Incus container LAN access.

## Overview

The system uses two `vmlan` interfaces to provide separate bridged network access paths:

- **vmlan0**: Dedicated for the NixOS VM's own LAN connectivity
- **vmlan1**: Dedicated for Incus containers' LAN connectivity via the `lan-br` bridge

This separation ensures that the VM and containers have independent network paths to the host's LAN, preventing conflicts and providing better network isolation.

## Network Architecture Diagram

```text
Host LAN (192.168.x.x/24)
    │
    ├── bond0/en0 (Physical Interface)
    │   │
    │   ├── vmlan0 ─── NixOS VM (Direct LAN access)
    │   │   └── VM gets DHCP directly from home router
    │   │
    │   └── vmlan1 ─── lan-br (Incus Bridge)
    │       └── Container lan0 interfaces get LAN access
    │
    └── Container Cluster Network
        └── vmnet-br (10.80.x.x/21) ─── Container vmnet0 interfaces
```

## Interface Configuration

### vmlan0 - VM LAN Interface

- **Purpose**: Direct LAN access for the NixOS VM
- **MAC Address**: `10:66:6a:4c:${hostByteHex}:01`
- **Bridge Target**: `bond0` (bioskop) or `en0` (other hosts)
- **IP Assignment**: VM gets IP directly from home router DHCP
- **Usage**: VM management, SSH access, general VM connectivity

### vmlan1 - Container LAN Interface

- **Purpose**: Dedicated interface for Incus `lan-br` bridge
- **MAC Address**: `10:66:6a:4c:${hostByteHex}:02`
- **Bridge Target**: `bond0` (bioskop) or `en0` (other hosts)
- **IP Assignment**: Interface remains unconfigured (no IP)
- **Usage**: Bridge external interface for container LAN access

## Lima Configuration

The Lima configuration (`lima-config.nix`) generates both interfaces:

```yaml
networks:
  - # vmlan0: VM direct LAN access
    lima: "bridged"
    interface: "vmlan0"
    macAddress: "10:66:6a:4c:${hostByteHex}:01"
  
  - # vmlan1: Incus lan-br bridge interface
    lima: "bridged"
    interface: "vmlan1" 
    macAddress: "10:66:6a:4c:${hostByteHex}:02"
```

## Incus Bridge Configuration

The Incus `lan-br` bridge uses `vmlan1` as its external interface:

```yaml
networks:
  - name: lan-br
    type: bridge
    config:
      ipv4.address: none          # No IP on bridge itself
      ipv6.address: none
      ipv4.dhcp: "false"         # No DHCP server on bridge
      ipv6.dhcp: "false"
      ipv4.nat: "false"          # No NAT - pure bridging
      ipv6.nat: "false"
      dns.mode: none
      bridge.driver: native
      bridge.external_interfaces: vmlan1  # Uses vmlan1 for LAN access
```

## Container Network Interfaces

Containers get two network interfaces:

### lan0 - LAN Access Interface

- **Network**: `lan-br` bridge
- **Purpose**: Internet access via home router
- **IP Assignment**: DHCP from home router (192.168.x.x/24)
- **Route**: Default route via home router (metric 100)
- **External Interface**: `vmlan1` → `bond0`/`en0` → home router

### vmnet0 - Cluster Interface

- **Network**: `vmnet-br` bridge (Incus-managed)
- **Purpose**: Inter-container cluster communication
- **IP Assignment**: Static DHCP from Incus (10.80.x.x/21)
- **Route**: Cluster-only (metric 9999)
- **External Interface**: None (isolated bridge)

## NixOS Configuration

### NetworkManager Exclusion

```nix
networking.networkmanager.unmanaged = [
  "interface-name:vmlan1"  # Prevent NetworkManager from managing vmlan1
];
```

### Interface Comments in Incus Preseed

```yaml
# vmlan0: Lima VM's own interface with IP for host management  
# vmlan1: Dedicated unconfigured interface for Incus lan-br bridge
```

## Verification Commands

### Check Interface Status

```bash
# On NixOS VM
ip link show vmlan0 vmlan1
ip addr show vmlan0 vmlan1

# Check bridge configuration
incus network show lan-br
incus network show vmnet-br
```

### Check Container Connectivity

```bash
# From container
ip route show  # Should see both lan0 and vmnet0 routes
ping 8.8.8.8   # Internet via lan0
ping 10.80.x.y # Cluster via vmnet0
```

## Troubleshooting

### vmlan1 Interface Missing

If `vmlan1` is not present after Lima startup:

1. Check Lima configuration includes both network entries
2. Restart Lima VM: `limactl stop nerd-nixos && limactl start nerd-nixos`
3. Verify socket_vmnet service is running on macOS

### Container LAN Access Issues

If containers cannot access LAN:

1. Verify `vmlan1` exists and is UP
2. Check `lan-br` bridge has `vmlan1` as external interface
3. Ensure home router DHCP pool has available addresses
4. Check container `lan0` interface has IP from home router

### Bridge Configuration Issues

```bash
# Reset lan-br bridge to use vmlan1
incus network set lan-br bridge.external_interfaces vmlan1
incus network set lan-br ipv4.address none
incus network set lan-br ipv4.dhcp false
incus network set lan-br ipv4.nat false
```

## Benefits of Dual-vmlan Architecture

1. **Network Isolation**: VM and containers have separate LAN access paths
2. **Independent Management**: VM networking doesn't affect container networking
3. **Scalability**: Can handle multiple bridges and network configurations
4. **Reliability**: Failure of one path doesn't affect the other
5. **Flexibility**: Each interface can have different configurations and policies

## Legacy Notes

Previously, containers used a single `lan-br` bridge with its own DHCP server (192.168.100.x/24) when `vmlan1` was missing. The dual-vmlan architecture eliminates this workaround by providing proper bridged access to the home router's DHCP server.
