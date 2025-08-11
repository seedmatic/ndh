# Podman Remote Engine Setup with Lima NixOS VM

This setup configures your Lima NixOS VM to act as a remote Podman engine accessible from your macOS host. This gives you a powerful container runtime with ZFS storage backing while keeping your host system clean.

## Overview

The configuration includes:

- **NixOS VM**: Podman engine with ZFS storage backend
- **macOS Host**: Podman client configured to connect remotely
- **Lima Integration**: Automatic port forwarding and SSH connectivity
- **Docker Compatibility**: Drop-in replacement for Docker commands

## Architecture

```
┌─────────────────┐         ┌─────────────────────┐
│   macOS Host    │         │   Lima NixOS VM     │
│                 │         │                     │
│ podman --remote │◄────────┤ Podman Engine       │
│ docker (alias)  │  SSH    │ + ZFS Storage       │
│                 │  2375   │ + API Socket        │
└─────────────────┘         └─────────────────────┘
```

## Setup Instructions

### 1. Rebuild Your Configuration

First, rebuild your nix-darwin configuration to get the client tools:

```bash
# From your nix-darwin-home directory
darwin-rebuild switch --flake .
```

### 2. Rebuild and Restart Lima VM

The NixOS configuration has been updated with Podman support. You'll need to rebuild the VM:

```bash
# Stop the VM if running
limactl stop nerd-nixos

# Start the VM (this will apply the new configuration)
limactl start nerd-nixos

# Or if you prefer to rebuild manually inside the VM:
lima nerd-nixos sudo nixos-rebuild switch
```

### 3. Setup Remote Connection

After the VM is running with the new configuration, set up the remote connection:

```bash
# Run the setup script
podman-remote-setup

# Or manually setup:
podman system connection add \
  --identity ~/.lima/_config/user \
  lima-nixos \
  ssh://nxmatic@$(limactl list nerd-nixos --format 'table' | grep nerd-nixos | awk '{print $4}')/run/podman/podman.sock

podman system connection default lima-nixos
```

### 4. Test the Setup

```bash
# Test basic connectivity
podman --remote info
podman --remote version

# Run a test container
podman --remote run --rm hello-world

# Test with docker alias
docker run --rm alpine echo "Hello from remote Podman!"
```

## Usage

### Available Commands

- `podman --remote <command>` - Use remote Podman explicitly
- `podman-lima <command>` - Convenient alias for remote Podman
- `docker <command>` - Docker compatibility alias
- `podman-remote-setup` - Reconnect to Lima VM (if IP changes)

### Container Storage

Containers are stored on ZFS in the VM at `/var/lib/containers/storage` using the `tank/nerd/containers` dataset. This provides:

- **Efficient snapshots**: Easy backup and rollback
- **Compression**: Automatic compression of container layers
- **Deduplication**: Shared layers across containers
- **Performance**: Optimized for container workloads

### Port Forwarding

The Lima configuration includes port forwarding for:
- `2375`: Podman API (HTTP)
- `2376`: Podman API (HTTPS, if configured)

### Networking

Containers can access:
- Host services via `host.containers.internal`
- Other containers via Podman's default bridge network
- External internet through the VM's NAT

## Advanced Usage

### Running Compose Files

```bash
# Use podman-compose with the remote engine
podman-compose --remote up -d

# Or create a wrapper script
alias docker-compose="podman-compose --remote"
```

### Building Images

```bash
# Build images remotely
podman --remote build -t myapp .

# Use buildah for advanced builds
lima nerd-nixos buildah build -t myapp .
```

### Volume Management

```bash
# Create and manage volumes
podman --remote volume create myvolume
podman --remote volume ls

# Volumes are stored in ZFS: tank/nerd/containers/volumes
```

## Troubleshooting

### VM Not Accessible

If the connection fails:

```bash
# Check VM status
limactl list

# Check SSH connectivity
lima nerd-nixos echo "VM is accessible"

# Check Podman service in VM
lima nerd-nixos sudo systemctl status podman.socket
```

### Port Conflicts

If port 2375 is already in use:

```bash
# Check what's using the port
lsof -i :2375

# Modify lima.yaml to use different ports if needed
```

### Storage Issues

Check ZFS storage in the VM:

```bash
# Check ZFS datasets
lima nerd-nixos sudo zfs list | grep containers

# Check available space
lima nerd-nixos df -h /var/lib/containers
```

### Reset Connection

If you need to reset the connection:

```bash
# Remove existing connections
podman system connection remove lima-nixos

# Re-run setup
podman-remote-setup
```

## Benefits

1. **Rootless on Host**: No privileged containers on macOS
2. **ZFS Benefits**: Snapshots, compression, deduplication
3. **Resource Isolation**: VM provides better resource control
4. **Linux Compatibility**: Full Linux container support
5. **Easy Cleanup**: VM can be easily rebuilt or destroyed
6. **Docker Compatibility**: Drop-in replacement for most Docker workflows

## Integration with Development

This setup works great with:
- VS Code with Remote-Containers extension
- Docker Compose projects
- Kubernetes development (containers run in Linux VM)
- CI/CD testing (consistent Linux environment)

The remote Podman engine provides a powerful, flexible container runtime while keeping your macOS host system clean and secure.
