# Bootstrap Guide: nix-darwin Linux Builder Setup

This guide covers the manual steps required to bootstrap a new nix-darwin system with the linux-builder configuration before the automated configuration can take over.

## Multi-Host Setup

This configuration supports multiple Darwin hosts:

- **alcide**: Darwin host (work profile)
- **bioskop**: Darwin host (committed profile)

Each host is defined in the `hosts/` directory:
- `hosts/alcide/flake.nix` - Configuration for alcide host
- `hosts/bioskop/flake.nix` - Configuration for bioskop host

The hosts can share linux-builders and perform distributed builds across each other via Tailscale networking.

## Overview

The nix-darwin linux-builder provides a NixOS VM that can build Linux packages on macOS. However, the initial setup requires some manual steps because:

1. SSH keys need to be generated and deployed
2. The `/etc/nix/machines` file needs initial builder entries
3. The VM needs to be created with proper disk size settings

## Prerequisites

- Nix with flakes support installed
- This flake configuration available
- flox installed (for `source <( flox activate )` at bootstrap)
- Admin access to modify `/etc/nix/machines`

**Note**: After installation, direnv will automatically load the flox environment when you enter the project directory.

## Bootstrap Steps

These steps apply to bootstrapping either host (alcide or bioskop). The process is the same, but each host will have its own profile and configuration.

### 0. Activate Flox Environment

At bootstrap time, you need to manually activate the flox environment since direnv isn't configured yet:

```bash
# Navigate to the flake directory
cd /path/to/nix-darwin-home

# Manually activate flox environment at bootstrap (before direnv is set up)
source <( flox activate )

# You should now have access to create-builder command
which create-builder
```

**Note**: After installation, the flox environment will be automatically loaded using direnv when you `cd` into the project directory.

### 1. Generate SSH Keys for Builder

First, generate SSH keys that will be used for builder authentication:

```bash
# Navigate to the flake directory
cd /path/to/nix-darwin-home

# Generate builder SSH keys if they don't exist
mkdir -p keys
ssh-keygen -t ed25519 -f keys/builder_ed25519 -N "" -C "nix-builder"

# The keys will be:
# - keys/builder_ed25519 (private key)
# - keys/builder_ed25519.pub (public key)
```

### 2. Initial /etc/nix/machines Setup

Before the full configuration can manage `/etc/nix/machines`, you need to create an initial entry manually:

```bash
# Create initial machines file (requires sudo)
sudo mkdir -p /etc/nix
sudo tee /etc/nix/machines > /dev/null << 'EOF'
# Initial bootstrap entry for darwin-linux-builder
ssh://builder@darwin-linux-builder aarch64-linux /etc/nix/builder_ed25519 4 1 nixos-test,benchmark,big-parallel,kvm - -
EOF
```

### 3. Deploy SSH Keys to System Location

The nix daemon needs access to the builder SSH key:

```bash
# Copy builder key to system location (requires sudo)
sudo cp keys/builder_ed25519 /etc/nix/builder_ed25519
sudo chmod 600 /etc/nix/builder_ed25519
sudo chown root:wheel /etc/nix/builder_ed25519
```

### 4. Initial Darwin Build

Now you can perform the first darwin build using `nix run` (since `darwin-rebuild` isn't in PATH yet). The build will use the host-specific configuration:

```bash
# For alcide host
nix run nix-darwin -- switch --flake ./hosts/alcide

# For bioskop host  
nix run nix-darwin -- switch --flake ./hosts/bioskop

# Or if building from within a host directory:
cd hosts/alcide  # or hosts/bioskop
nix run nix-darwin -- switch --flake .

# This may take some time as it:
# - Downloads the NixOS base system
# - Creates the VM disk image
# - Configures the VM with host-specific settings
```

### 5. Create the Builder VM

Use the `create-builder` command from the flox environment to set up the builder:

```bash
# Ensure flox environment is activated
flox activate

# Create the linux-builder VM
create-builder

# This command will:
# - Set up the linux-builder VM with proper configuration
# - Configure networking and SSH access
# - Prepare the VM for builds
```

### 6. Verify Builder Connection

After the build and builder creation completes, test the builder connection:

```bash
# Test SSH connection to the builder
ssh darwin-linux-builder

# Check disk space in the VM
df -h

# Exit the VM
exit
```

You should see the VM has the configured disk size (150GB by default) rather than the standard 20GB.

### 7. Test a Linux Build

Verify that Linux builds work:

```bash
# Test building a simple Linux package
nix build --system aarch64-linux nixpkgs#hello

# This should use the linux-builder VM
```

## Building and Running NixOS in Lima

After the darwin configuration is set up, you can build and run NixOS disk images using Lima.

### 1. Build the NixOS Disk Image

Build the disk image for the host you're currently running on:

```bash
# If you're on bioskop, build bioskop's NixOS disk image
nix build ./hosts/bioskop#nixosDiskImage

# If you're on alcide, build alcide's NixOS disk image  
nix build ./hosts/alcide#nixosDiskImage

# This creates a disk image at ./result/nixos.img
# The build uses the increased linux-builder disk size to avoid space issues
```

**Note**: Build only the image for your current host - each host has its own specific NixOS configuration and disk image.

### 2. Start NixOS VM in Lima

Navigate to the Lima configuration directory and start the VM:

```bash
# Navigate to Lima directory
cd ~/.lima

# Source the flox environment (provides Lima management tools)
source <( flox activate )

# Start the nerd-nixos VM
# (This uses the disk image built in step 1)
limactl start nerd-nixos

# Or follow your specific Lima startup procedure
```

**Note**: The Lima configuration should reference the disk image path `./result/nixos.img` created by the nix build command.

## Configuration Details

### Flox Environment Integration

The setup relies on a flox environment that provides:

- `create-builder`: Command to set up and manage the linux-builder VM
- Additional build tools and utilities
- Consistent development environment across hosts

**Bootstrap vs Post-Installation**:
- **At bootstrap**: Use `source <( flox activate )` since direnv isn't configured yet
- **After installation**: The flox environment is automatically loaded via direnv when you enter the project directory

The direnv integration ensures that development tools are always available without manual activation once the initial setup is complete.

### Default vs Configured Disk Sizes

- **Default nix-darwin linux-builder disk size**: 20GB (20480 MB)
- **Our configured linux-builder disk size**: 150GB (153600 MB) using `lib.mkForce`
- **NixOS disk image size**: 18GB (18432 MB) as configured in flake.nix

The `lib.mkForce` is necessary because the default NixOS builder profile sets a smaller disk size that conflicts with our larger requirement for building disk images.

**Why the larger linux-builder disk?**
The linux-builder VM needs significantly more space than the final disk image because:
- It stores the entire Nix store during the build process
- It needs working space for temporary files during image creation
- It requires space for multiple concurrent builds
- The 150GB provides comfortable headroom for building 18GB (or larger) disk images

### SSH Key Management

The configuration uses a single builder key name across the system:

- `/etc/nix/keys.d/builder_ed25519`: System key for the nix daemon and remote builders
- `~/.ssh/keys.d/linux_builder`: User-accessible copy (legacy, optional)

### Binary Cache Configuration

The linux-builder VM is configured with the same binary caches as the Darwin host:

- Standard cache.nixos.org
- flox cache (cache.flox.dev) 
- Determinate Systems FlakeHub cache (cache.flakehub.com)

## Troubleshooting

### Disk Size Conflicts

If you see an error like:
```
error: The option `virtualisation.diskSize' has conflicting definition values:
```

This means the default 20GB conflicts with your configured size. The fix is already applied using `lib.mkForce`.

### SSH Connection Issues

If `ssh darwin-linux-builder` fails:

1. Check if the VM is running: `pgrep qemu`
2. Verify SSH key permissions: `ls -la /etc/nix/builder_ed25519*`
3. Check SSH configuration: `ssh -v darwin-linux-builder`

### Builder Not Found

If nix can't find the builder:

1. Check `/etc/nix/machines` exists and has the correct entry
2. Verify the SSH key path in the machines file matches the actual key location
3. Test SSH connection manually before trying builds

### macOS Bootstrap Recovery Path

If Darwin bootstrap becomes unreliable (for example: repeated activation failures, first-login provisioning drift, or fragile UI-driven setup behavior), use the dedicated macOS image bootstrap workflow from the sibling repository:

- `../macos-image-template@nxmatic/README.adoc`

That project is the preferred fallback to recover a clean, reproducible macOS base image (Tart/Packer + flox tooling) before retrying this `nix-darwin-home` bootstrap.

## Post-Bootstrap

After successful bootstrap, you can continue to use either:

```bash
# Using nix run (works anywhere)
nix run nix-darwin -- switch --flake .

# Or if darwin-rebuild is now in your PATH
darwin-rebuild switch --flake .
```

If `bioskop` already built the same system closure, you can copy it directly instead of rebuilding locally:

```bash
# Example: copy a prebuilt darwin closure from bioskop
nix copy --from ssh-ng://nxmatic@bioskop /nix/store/bsxz8jp32k0rapkbrv7mchgxv26g0rch-darwin-system-25.11.688427b.drv
```

This is useful right after bootstrap to speed up the first `switch` on another Darwin host.

The configuration will automatically:

- Manage `/etc/nix/machines` with proper entries
- Handle SSH key deployment and permissions
- Configure distributed builds to other hosts (if enabled)
- Maintain binary cache settings

The manual steps above are only needed once per new system setup.

## Advanced: Cross-Host Distributed Builds

This configuration supports distributed builds between the two Darwin hosts:

### Host Configuration
- **alcide** (work profile: stephane.lacoin)
  - Primary builder: Local darwin-linux-builder (speedFactor: 2)
  - Secondary builder: bioskop's linux-builder via Tailscale (speedFactor: 3)
  
- **bioskop** (committed profile: nxmatic)  
  - Primary builder: Local darwin-linux-builder (speedFactor: 3)
  - Secondary builder: alcide's linux-builder via Tailscale (speedFactor: 2)

### Cross-Host Access
- Uses SSH ProxyJump through Tailscale for secure remote access
- Each host can utilize the other's linux-builder as a fallback
- bioskop's builder is preferred (higher speedFactor) due to better resources

### Host Directory Structure
```
hosts/
├── alcide/
│   ├── flake.nix          # alcide host configuration
│   └── flake.lock
└── bioskop/
    ├── flake.nix          # bioskop host configuration  
    └── flake.lock
```

Each host imports the main configuration but applies host-specific profiles and settings.

This requires additional SSH configuration and Tailscale setup, which is handled automatically after bootstrap.
