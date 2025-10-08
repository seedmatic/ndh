# Teleport Integration Summary

## Files Created/Modified

### New Modules

1. **`modules/darwin/teleport.nix`** (Enhanced)
   - Teleport auth/proxy server for macOS
   - Integrated with Tailscale for hostname resolution
   - Configurable via `services.teleport.*` options

2. **`modules/nixos/teleport-node.nix`** (New)
   - Teleport SSH node service for Linux VMs
   - Systemd service with security hardening
   - Configurable via `services.teleport-node.*` options

3. **`modules/common/teleport/roles.nix`** (New)
   - RBAC role definitions (committed, work, linux-builder)
   - `teleport-import-roles` helper script

4. **`modules/common/teleport/setup.nix`** (New)
   - `teleport-setup` - Initial cluster setup
   - `teleport-status` - Cluster status checker
   - `teleport-connect` - Quick SSH helper

### Modified Files

1. **`modules/darwin/default.nix`**
   - Added `./teleport.nix` to imports
   - Disabled `./openssh.nix` (commented out)

2. **`modules/nixos/default.nix`**
   - Added `./teleport-node.nix` to imports

3. **`modules/common/default.nix`**
   - Added `./teleport` to imports (which loads roles.nix and setup.nix)

4. **`modules/home-manager/default.nix`**
   - Disabled `./ssh-keys.nix` (commented out)
   - Disabled `./ssh-keychain-removal.nix` (commented out)

### Documentation

1. **`docs/teleport-setup.md`** (New)
   - Complete setup guide
   - Configuration examples
   - Troubleshooting tips

## Module Structure

```
modules/
├── common/
│   ├── default.nix                    # ✓ Updated
│   └── teleport/
│       ├── roles.nix                  # ✓ New
│       └── setup.nix                  # ✓ New
├── darwin/
│   ├── default.nix                    # ✓ Updated
│   └── teleport.nix                   # ✓ Enhanced
└── nixos/
    ├── default.nix                    # ✓ Updated
    └── teleport-node.nix              # ✓ New
```

## Available Helper Scripts

All scripts use `set -euxo pipefail` for better debugging:

- **`teleport-setup`** - Initial cluster setup (creates admin, generates tokens, imports roles)
- **`teleport-status`** - Show cluster status (nodes, users, roles)
- **`teleport-connect <node>`** - Quick SSH to a node via Teleport
- **`teleport-import-roles`** - Import RBAC roles into cluster

## Configuration Options

### Darwin (Auth/Proxy Server)

```nix
services.teleport = {
  enable = true;              # Enable Teleport
  authServer = true;          # Run auth service
  proxyService = true;        # Run proxy/web UI
  sshService = true;          # Allow SSH into this host
  clusterName = "...";        # Cluster name
  webPort = 3080;             # Web UI port
  logLevel = "INFO";          # Log level
  environment = "...";        # Environment label
  joinToken = "...";          # Node join token
  acme.enabled = false;       # ACME for TLS
  acme.email = "...";         # ACME email
};
```

### NixOS (SSH Node)

```nix
services.teleport-node = {
  enable = true;
  authServer = "host.ts.net:3025";  # Auth server address
  authToken = "...";                # Join token
  logLevel = "INFO";
  environment = "...";
  commands = {                      # Dynamic labels
    hostname = [ "hostname" ];
  };
};
```

## Quick Start

### 1. Enable on Darwin

```nix
# hosts/bioskop/configuration.nix
{
  services.teleport = {
    enable = true;
    clusterName = "mammoth-skate";
    joinToken = "your-secure-token";
  };
}
```

### 2. Rebuild and Setup

```bash
darwin-rebuild switch --flake .#bioskop
teleport-setup
```

### 3. Enable on Linux VM

```nix
# hosts/linux-builder/configuration.nix
{
  services.teleport-node = {
    enable = true;
    authServer = "bioskop.mammoth-skate.ts.net:3025";
    authToken = "node-join-token";  # From teleport-setup
  };
}
```

### 4. Rebuild Linux VM

```bash
nixos-rebuild switch --flake .#linux-builder
```

## Usage

```bash
# Login
tsh login --proxy=bioskop.mammoth-skate.ts.net:3080

# List nodes
tsh ls

# SSH to node
tsh ssh linux-builder

# Or use helper
teleport-connect linux-builder

# Check status
teleport-status
```

## Integration with Existing Infrastructure

- **Tailscale**: All Teleport traffic uses Tailscale mesh network
- **SSH Certificates**: Can run alongside existing SSH setup during migration
- **RBAC**: Roles map to existing `committed`, `work`, `linux-builder` principals
- **No Public Exposure**: Everything stays within the Tailnet

## Next Steps

1. Generate secure join token: `openssl rand -hex 32`
2. Enable Teleport in host configurations
3. Run `teleport-setup` on Darwin host
4. Enable nodes on Linux VMs
5. Test access with `tsh` or `teleport-connect`

See `docs/teleport-setup.md` for detailed instructions!
