# Network Monitor Configuration Examples

This document shows how to configure the network monitor for different scenarios on bioskop.

## Current Configuration (Individual Interface Mode)

Since bonding is disabled in `/hosts/bioskop/flake.nix`, the network monitor will run in individual mode:

```nix
# In hosts/bioskop/flake.nix
darwinModule = { config, lib, ... }: {
  config = {
    # Network bonding disabled - monitor runs in individual mode
    networking.bond = {
      enable = false;
      interfaces = [ "en0" "en8" ];
      mode = "static";
    };

    # Network monitor - automatically detects individual mode
    networking.monitor = {
      enable = true;
      # These are the defaults and will be used automatically:
      # mode = "individual";  # Auto-detected from bond.enable = false
      # primaryInterface = "en0";    # Built-in Ethernet (highest priority)
      # backupInterface = "en1";     # Wi-Fi (backup when en0 fails)
      # disabledInterfaces = ["en8"]; # USB Ethernet (disabled to avoid conflicts)
      # checkInterval = 30;          # Check every 30 seconds
    };
  };
};
```

## Configuration for Bonded Mode

If you want to enable bonding and have the monitor manage the bond interface:

```nix
# In hosts/bioskop/flake.nix
darwinModule = { config, lib, ... }: {
  config = {
    # Enable network bonding
    networking.bond = {
      enable = true;
      interfaces = [ "en0" "en8" ];
      mode = "static"; # or "lacp" if your router supports it
    };

    # Network monitor - automatically detects bonded mode
    networking.monitor = {
      enable = true;
      # These will be used automatically:
      # mode = "bonded";        # Auto-detected from bond.enable = true
      # bondInterface = "bond0"; # Monitor and maintain bond0
      # checkInterval = 30;     # Check every 30 seconds
    };
  };
};
```

## Service Behavior

### Individual Mode (Current)
- **Primary Interface (en0)**: Gets default route priority
- **Backup Interface (en1/Wi-Fi)**: Keeps IP but no default route, used for failover
- **Disabled Interfaces (en8)**: Powered down to avoid conflicts
- **Lima Bridges**: Default routes removed to prevent conflicts

### Bonded Mode
- **Bond Interface (bond0)**: Monitored for IP and connectivity
- **Member Interfaces (en0, en8)**: Managed by bond, no individual IPs
- **Wi-Fi**: Default route removed, bond takes priority
- **Lima Bridges**: Default routes removed to prevent conflicts

## Logs and Monitoring

Both modes create detailed logs:

```bash
# Main monitoring service logs
tail -f /var/log/network-monitor.log

# Event-driven service logs (responds to network changes)
tail -f /var/log/network-monitor-events.log

# For bonded mode, also check:
tail -f /var/log/network-bond.log
```

## Switching Between Modes

To switch from individual to bonded mode:

1. **Update configuration**:
   ```nix
   networking.bond.enable = true;  # Change from false to true
   ```

2. **Rebuild system**:
   ```bash
   darwin-rebuild switch --flake .
   ```

3. **The network monitor will automatically switch modes** on the next system activation.

To switch back to individual mode, reverse the process:

1. **Update configuration**:
   ```nix
   networking.bond.enable = false;  # Change from true to false
   ```

2. **Rebuild system**:
   ```bash
   darwin-rebuild switch --flake .
   ```

## Manual Network Fixes

If you need to manually fix network issues without rebuilding:

```bash
# Run the manual network fix script (individual mode)
./bin/fix-dual-interface-network.sh

# Or manually disable conflicting interfaces
sudo ifconfig en8 down
sudo route -n delete default -ifscope en1 2>/dev/null || true
```