# Teleport + Tailscale Setup Guide

This guide explains how to deploy Teleport across your Darwin hosts and Linux VMs using the Nix modules in this repository.

## Architecture

- **Darwin hosts** (e.g., `bioskop`): Run Teleport auth + proxy + SSH services
- **Linux VMs** (e.g., `linux-builder`): Run Teleport SSH node service
- **Tailscale**: Provides secure mesh networking between all nodes
- **No public exposure**: All Teleport traffic stays within the Tailnet

## Quick Start

### 1. Enable Teleport on Darwin (Auth Server)

In your Darwin host configuration (e.g., `hosts/bioskop/configuration.nix`):

```nix
{
  imports = [
    ../../modules/darwin/teleport.nix
    ../../modules/common/teleport/roles.nix
    ../../modules/common/teleport/setup.nix
  ];

  services.teleport = {
    enable = true;
    authServer = true;
    proxyService = true;
    sshService = true;
    clusterName = "mammoth-skate";
    webPort = 3080;  # Use non-privileged port
    environment = "production";
    # Generate a secure token: openssl rand -hex 32
    joinToken = "your-secure-token-here";
  };
}
```

### 2. Rebuild and Start Teleport

```bash
# Rebuild Darwin configuration
darwin-rebuild switch --flake .#bioskop

# The service will start automatically via launchd
# Check status
sudo launchctl list | grep teleport

# View logs
tail -f ~/.local/state/log/teleport.log
```

### 3. Bootstrap Admin Users

After the first rebuild, you'll see a message to run the first-time setup:

```bash
# Run the bootstrap script
teleport-first-run

# This will:
# - Wait for Teleport to start
# - Import RBAC roles (admin, committed, work, linux-builder)
# - Create Teleport users for all members of admin/wheel groups
# - Generate signup links for each user
```

**Example output:**
```
+ : 'Creating admin users from admin/wheel group'
+ : 'Creating Teleport user for: nxmatic'
User "nxmatic" has been created but requires a password. Share this URL with the user to complete user setup, link is valid for 1h:
https://bioskop.mammoth-skate.ts.net:3080/web/invite/abc123...

✅ User 'nxmatic' created! Use the signup link above to set password.
✅ Setup complete!
```

### 4. Complete User Setup

1. **Open the signup URL** in your browser (accept the self-signed cert warning)
2. **Set your password**
3. **Configure 2FA** (optional but recommended)
4. **Complete setup**

### 5. Enable Teleport Node on Linux VM

In your Linux VM configuration (e.g., `hosts/linux-builder/configuration.nix`):

```nix
{
  imports = [
    ../../modules/nixos/teleport-node.nix
  ];

  services.teleport-node = {
    enable = true;
    authServer = "bioskop.mammoth-skate.ts.net:3025";
    authToken = "your-node-join-token";  # From teleport-setup output
    environment = "production";
    commands = {
      # Dynamic labels
      hostname = [ "hostname" ];
      kernel = [ "uname" "-r" ];
    };
  };
}
```

### 6. Rebuild Linux VM

```bash
# On the Linux VM
sudo nixos-rebuild switch --flake .#linux-builder

# Check service status
systemctl status teleport-node
```

## Usage

### Web UI Access

Access the Teleport web UI via Tailscale:

```bash
open https://bioskop.mammoth-skate.ts.net:3080
```

### CLI Access

```bash
# Login to Teleport
tsh login --proxy=bioskop.mammoth-skate.ts.net:3080 --user=admin --insecure

# List available nodes
tsh ls

# SSH into a node
tsh ssh linux-builder

# Or use the helper script
teleport-connect linux-builder

# Check cluster status
teleport-status
```

### Managing Users

```bash
# Create a new user
tctl users add alice --roles=committed --logins=alice,nxmatic

# Update user roles
tctl users update alice --set-roles=committed,work

# List users
tctl users ls
```

### Managing Tokens

```bash
# Generate a new node token (24h TTL)
tctl tokens add --type=node --ttl=24h

# List active tokens
tctl tokens ls
```

## RBAC Roles

Three roles are pre-configured:

### `committed`
- **Logins**: `nxmatic`, `root`
- **Access**: All nodes in `development` and `production` environments
- **Session TTL**: 8 hours
- **Permissions**: Read-only access to cluster resources

### `work`
- **Logins**: `nxmatic`, `stephane.lacoin`
- **Access**: All nodes in all environments
- **Kubernetes**: `system:masters` group
- **Session TTL**: 12 hours
- **Permissions**: Full admin access

### `linux-builder`
- **Logins**: `builder`, `nxmatic`
- **Access**: Only nodes with `hostname=linux-builder` label
- **Session TTL**: 24 hours

## Configuration Options

### Darwin (Auth/Proxy)

```nix
services.teleport = {
  enable = true;
  authServer = true;        # Enable auth service
  proxyService = true;      # Enable proxy/web UI
  sshService = true;        # Allow SSH into this host
  clusterName = "...";      # Cluster identifier
  webPort = 3080;           # Web UI port
  logLevel = "INFO";        # DEBUG|INFO|WARN|ERROR
  environment = "...";      # Environment label
  joinToken = "...";        # Node join token
  acme = {
    enabled = false;        # Auto TLS certs
    email = "...";
  };
};
```

### NixOS (Node)

```nix
services.teleport-node = {
  enable = true;
  authServer = "...";       # Auth server address
  authToken = "...";        # Join token
  logLevel = "INFO";
  environment = "...";
  commands = {              # Dynamic labels
    hostname = [ "hostname" ];
  };
};
```

## Troubleshooting

### Check Logs

**Darwin:**
```bash
tail -f /Users/nxmatic/.local/var/log/teleport.log
```

**Linux:**
```bash
journalctl -u teleport-node -f
```

### Verify Tailscale Connectivity

```bash
# Ping the auth server
tailscale ping bioskop.mammoth-skate.ts.net

# Check Tailscale status
tailscale status
```

### Reset Teleport Data

**Darwin:**
```bash
sudo launchctl unload /Library/LaunchDaemons/com.gravitational.teleport.plist
rm -rf /Users/nxmatic/.local/var/teleport
sudo launchctl load /Library/LaunchDaemons/com.gravitational.teleport.plist
```

**Linux:**
```bash
sudo systemctl stop teleport-node
sudo rm -rf /var/lib/teleport
sudo systemctl start teleport-node
```

## Security Best Practices

1. **Use strong join tokens**: Generate with `openssl rand -hex 32`
2. **Rotate tokens regularly**: Set short TTLs and regenerate
3. **Enable ACME in production**: For automatic TLS certificates
4. **Review audit logs**: Check session recordings in web UI
5. **Use role-based access**: Assign minimal required permissions
6. **Keep Teleport updated**: Monitor for security patches

## Migration from SSH Certificates

### Current Status: Phase 1 (Parallel Operation)

The SSH certificate infrastructure has been **disabled** (not removed) to allow safe migration:

**Disabled Modules:**
- `modules/darwin/openssh.nix` - Custom sshd with certificate support
- `modules/home-manager/ssh-keys.nix` - Key generation and certificate deployment
- `modules/home-manager/ssh-keychain-removal.nix` - Keychain integration

**Still Active:**
- `modules/home-manager/ssh.nix` - Basic SSH client configuration
- `modules/home-manager/ssh-tailnet-hosts.nix` - Tailscale hostname resolution
- `modules/home-manager/keychain.nix` - SSH agent (works with Teleport)

### Migration Phases

#### Phase 1: Parallel Operation (Current)
- ✅ Teleport modules enabled
- ✅ SSH certificate modules disabled
- ✅ Basic SSH client still works
- ✅ Can test Teleport without breaking workflows

#### Phase 2: Validation

1. **Deploy Teleport**
   ```bash
   # Enable in your host configuration
   services.teleport.enable = true;  # Darwin
   services.teleport-node.enable = true;  # NixOS
   
   # Rebuild
   darwin-rebuild switch --flake .#bioskop
   nixos-rebuild switch --flake .#linux-builder
   ```

2. **Initial Setup**
   ```bash
   teleport-setup
   ```

3. **Test Access**
   ```bash
   tsh login --proxy=bioskop.mammoth-skate.ts.net:3080
   tsh ls
   tsh ssh linux-builder
   ```

4. **Verify RBAC**
   ```bash
   teleport-status
   tctl get roles
   ```

#### Phase 3: Full Cutover

Once validated, rebuild all hosts with Teleport as primary access method.

#### Phase 4: Cleanup (Optional)

After confirming everything works, remove disabled modules:
```bash
rm modules/darwin/openssh.nix
rm modules/home-manager/ssh-keys.nix
rm modules/home-manager/ssh-keychain-removal.nix
rm modules/home-manager/ssh-generate-keys-yaml.sh
rm modules/home-manager/ssh-extract-keys.sh
rm -rf modules/common/ssh/
```

### Rollback Plan

If needed, re-enable SSH certificates:

```nix
# modules/darwin/default.nix
./openssh.nix  # Uncomment

# modules/home-manager/default.nix
./ssh-keys.nix  # Uncomment
./ssh-keychain-removal.nix  # Uncomment
```

Then disable Teleport and rebuild.

### Key Differences

| Feature | SSH Certificates | Teleport |
|---------|-----------------|----------|
| **Authentication** | Manual cert signing | Automatic short-lived certs |
| **Access Control** | File-based principals | RBAC with roles |
| **Audit Logs** | syslog only | Full session recording |
| **Web UI** | None | Built-in |
| **Key Management** | Manual | Automatic via `tsh` |
| **Certificate Rotation** | Manual | Automatic on login |
| **Multi-factor Auth** | External (PAM) | Built-in (U2F, TOTP) |
| **Kubernetes** | Separate | Integrated |

## References

- [Teleport Documentation](https://goteleport.com/docs/)
- [Tailscale Documentation](https://tailscale.com/kb/)
- [Teleport RBAC Guide](https://goteleport.com/docs/access-controls/guides/role-templates/)
