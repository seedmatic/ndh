# Alcide Setup Quick Reference

## Architecture Overview

```
┌─────────────────────────────────────────┐
│ macOS Host (alcide)                     │
│ - JAMF Managed                          │
│ - Minimal nix installation              │
│ - Nix, Lima, SSH, basic tools only      │
└────────────┬────────────────────────────┘
             │ SSH / Lima
             │
┌────────────▼────────────────────────────┐
│ Lima NixOS VM (alcide-nixos)            │
│ - All development tools                 │
│ - Git, editors, IDEs                    │
│ - Container tools (kubectl, k9s, helm)  │
│ - Incus container runtime               │
└────────────┬────────────────────────────┘
             │ incus / kubectl
             │
┌────────────▼────────────────────────────┐
│ Incus Cluster (in VM)                   │
│ - RKE2 Kubernetes                       │
│ - Application containers                │
│ - Databases, services                   │
└─────────────────────────────────────────┘
```

## What Goes Where

### macOS Host (Minimal)
✅ Nix, Lima, Flox, Direnv
✅ Basic shells (bash, zsh)
✅ Git (for flake updates only)
✅ SSH client
✅ Tailscale client

❌ Development tools
❌ Editors (emacs, vim, vscode)
❌ Container tools
❌ Build tools
❌ Language runtimes

### Lima VM (Full Development)
✅ All development tools
✅ Editors: emacs-nox, vim, neovim
✅ Container tools: incus, kubectl, k9s, helm
✅ Build tools: gcc, make, cargo, etc.
✅ Language runtimes: Python, Node.js, Go, Rust
✅ Monitoring: htop, tcpdump, wireshark
✅ Services: databases, web servers

### Incus Cluster (Applications)
✅ RKE2 Kubernetes cluster
✅ Application workloads
✅ Microservices
✅ Persistent data services
✅ Dev/staging environments

## Quick Commands

### Managing the VM

```bash
# Start VM
limactl start nerd-nixos

# Check VM status
limactl list

# SSH into VM (option 1)
limactl shell nerd-nixos

# SSH into VM (option 2 - direct)
ssh alcide-nixos  # add to ~/.ssh/config

# Stop VM
limactl stop nerd-nixos
```

### Working in the VM

```bash
# Access your development environment
limactl shell nerd-nixos

# All tools are available here:
git clone <repo>
emacs <file>
kubectl get pods
incus list
```

### Updating Systems

```bash
# Update macOS host config (minimal)
cd ~/Gits/nxmatic/nix-darwin-home/hosts/alcide
darwin-rebuild switch --flake .#alcide

# Update VM (inside VM)
sudo nixos-rebuild switch --flake /path/to/config
```

### Accessing Services

```bash
# Access VM service from macOS (port forward)
ssh -L 8080:localhost:8080 alcide-nixos

# Access cluster service from VM
kubectl port-forward svc/myapp 8080:80

# Or expose via Tailscale
```

## SSH Configuration

Add to `~/.ssh/config` on macOS:

```
Host alcide-nixos
  HostName 192.168.5.X  # Get IP: limactl list
  User nxmatic
  ForwardAgent yes
  ServerAliveInterval 60
```

## Using Editors

### Emacs via SSH/TRAMP

From macOS, open file in VM:
```elisp
C-x C-f /ssh:alcide-nixos:/path/to/file
```

### VS Code Remote SSH

1. Install "Remote - SSH" extension
2. Add alcide-nixos to SSH config
3. Connect to host
4. Open folder in VM

### Terminal Editors

```bash
# SSH into VM and use editors there
limactl shell nerd-nixos
vim myfile.txt
# or
emacs -nw myfile.txt
```

## Migration Steps

If you have existing alcide with packages:

1. **Backup current state**
   ```bash
   darwin-rebuild --flake .#alcide build
   ```

2. **Switch to minimal config**
   ```bash
   cd ~/Gits/nxmatic/nix-darwin-home
   git pull
   darwin-rebuild switch --flake ./hosts/alcide#alcide
   ```

3. **Start Lima VM**
   ```bash
   limactl start nerd-nixos
   ```

4. **Move projects to VM**
   ```bash
   scp -r ~/Projects alcide-nixos:~/
   ```

5. **Work in VM from now on**
   ```bash
   limactl shell nerd-nixos
   cd ~/Projects
   ```

## Troubleshooting

### VM won't start
```bash
limactl list
limactl stop nerd-nixos
limactl start nerd-nixos
```

### Can't SSH
```bash
# Check VM IP
limactl shell nerd-nixos ip addr

# Test connection
ssh -v nxmatic@<vm-ip>
```

### Need to rebuild VM
```bash
limactl stop nerd-nixos
limactl delete nerd-nixos
# Then rebuild from Darwin config
darwin-rebuild switch --flake .#alcide
limactl start nerd-nixos
```

## Files Created/Modified

- `profiles/work-minimal.nix` - Minimal profile for JAMF-managed hosts
- `modules/common/system-packages-minimal.nix` - Minimal system packages
- `hosts/alcide/flake.nix` - Updated to use minimal profile
- `hosts/alcide/nixos-vm-config.nix` - Full VM configuration
- `docs/alcide-minimal-host.adoc` - Detailed documentation

## Benefits

✅ **JAMF Compliance**: Minimal changes to managed macOS
✅ **Isolation**: Dev work isolated from host
✅ **Flexibility**: Easy to recreate/reset VM
✅ **Performance**: VM has direct hardware access via Lima
✅ **Portability**: Same config works on any host
✅ **Security**: Container isolation for apps

## Next Steps

1. Review the configuration files
2. Test the minimal Darwin build: `darwin-rebuild build --flake ./hosts/alcide#alcide`
3. Apply when ready: `darwin-rebuild switch --flake ./hosts/alcide#alcide`
4. Start the Lima VM and verify tools are available
5. Migrate your projects to the VM
6. Update your workflow to work primarily in the VM
