#!/usr/bin/env bash
# Podman Remote Engine Health Check Script (@codebase)
# Verifies that the Lima NixOS VM is properly configured with Podman remote engine

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
VM_NAME="nerd-nixos"
LIMA_USER="nxmatic"

print_status() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

check_lima_vm() {
    print_status "Checking Lima VM status..."
    
    if ! command -v limactl >/dev/null 2>&1; then
        print_error "Lima is not installed or not in PATH"
        return 1
    fi
    
    if ! limactl list | grep -q "$VM_NAME"; then
        print_error "Lima VM '$VM_NAME' not found"
        return 1
    fi
    
    if limactl list | grep "$VM_NAME" | grep -q "Running"; then
        print_success "Lima VM '$VM_NAME' is running"
        return 0
    else
        print_error "Lima VM '$VM_NAME' is not running"
        echo "💡 Start it with: limactl start $VM_NAME"
        return 1
    fi
}

check_vm_connectivity() {
    print_status "Checking VM SSH connectivity..."
    
    if lima "$VM_NAME" echo "VM accessible" >/dev/null 2>&1; then
        print_success "SSH connectivity to VM working"
        return 0
    else
        print_error "Cannot connect to VM via SSH"
        return 1
    fi
}

check_podman_in_vm() {
    print_status "Checking Podman installation in VM..."
    
    if lima "$VM_NAME" command -v podman >/dev/null 2>&1; then
        print_success "Podman is installed in VM"
        local version=$(lima "$VM_NAME" podman --version)
        print_status "Version: $version"
        return 0
    else
        print_error "Podman is not installed in VM"
        return 1
    fi
}

check_podman_service() {
    print_status "Checking Podman service in VM..."
    
    if lima "$VM_NAME" sudo systemctl is-active podman.socket >/dev/null 2>&1; then
        print_success "Podman socket service is active"
    else
        print_warning "Podman socket service is not active"
        print_status "Attempting to start Podman socket..."
        lima "$VM_NAME" sudo systemctl start podman.socket || {
            print_error "Failed to start Podman socket"
            return 1
        }
        print_success "Podman socket started"
    fi
    
    return 0
}

check_zfs_storage() {
    print_status "Checking ZFS container storage..."
    
    if lima "$VM_NAME" sudo zfs list tank/containers >/dev/null 2>&1; then
        print_success "ZFS dataset 'tank/containers' exists"
        local usage=$(lima "$VM_NAME" sudo zfs list -H -o used tank/containers)
        print_status "Storage used: $usage"
        return 0
    else
        print_warning "ZFS dataset 'tank/containers' not found"
        print_status "This will be created automatically when Podman starts"
        return 0
    fi
}

check_host_podman() {
    print_status "Checking Podman client on host..."
    
    if command -v podman >/dev/null 2>&1; then
        print_success "Podman client is installed on host"
        local version=$(podman --version)
        print_status "Version: $version"
        return 0
    else
        print_error "Podman client is not installed on host"
        return 1
    fi
}

check_remote_connection() {
    print_status "Checking Podman remote connection..."
    
    if podman system connection list | grep -q "lima-nixos"; then
        print_success "Remote connection 'lima-nixos' exists"
        
        if podman system connection list | grep "lima-nixos" | grep -q "true"; then
            print_success "Remote connection is set as default"
        else
            print_warning "Remote connection exists but is not default"
        fi
        
        return 0
    else
        print_warning "Remote connection 'lima-nixos' not configured"
        return 1
    fi
}

test_remote_podman() {
    print_status "Testing remote Podman functionality..."
    
    if podman --remote info >/dev/null 2>&1; then
        print_success "Remote Podman info command works"
    else
        print_error "Remote Podman info command failed"
        return 1
    fi
    
    print_status "Testing container run..."
    if podman --remote run --rm alpine:latest echo "Hello from remote Podman!" >/dev/null 2>&1; then
        print_success "Remote container execution works"
    else
        print_error "Remote container execution failed"
        return 1
    fi
    
    return 0
}

setup_remote_connection() {
    print_status "Setting up remote connection..."
    
    local vm_ip
    vm_ip=$(limactl list "$VM_NAME" --format 'table' | grep "$VM_NAME" | awk '{print $4}' | head -1)
    
    if [ -z "$vm_ip" ] || [ "$vm_ip" = "-" ]; then
        print_error "Could not determine VM IP"
        return 1
    fi
    
    print_status "VM IP: $vm_ip"
    
    # Remove existing connection
    podman system connection remove lima-nixos 2>/dev/null || true
    
    # Add new connection
    podman system connection add \
        --identity ~/.lima/_config/user \
        lima-nixos \
        "ssh://$LIMA_USER@$vm_ip/run/podman/podman.sock"
    
    # Set as default
    podman system connection default lima-nixos
    
    print_success "Remote connection configured"
    return 0
}

main() {
    echo "🔍 Podman Remote Engine Health Check"
    echo "======================================"
    
    local failed=0
    
    # Basic checks
    check_lima_vm || failed=1
    [ $failed -eq 0 ] && check_vm_connectivity || failed=1
    [ $failed -eq 0 ] && check_podman_in_vm || failed=1
    [ $failed -eq 0 ] && check_podman_service || failed=1
    check_zfs_storage || true  # Don't fail on this
    check_host_podman || failed=1
    
    # Connection checks
    check_remote_connection || {
        print_status "Attempting to setup remote connection..."
        setup_remote_connection || failed=1
    }
    
    # Functional tests
    [ $failed -eq 0 ] && test_remote_podman || failed=1
    
    echo
    if [ $failed -eq 0 ]; then
        print_success "🎉 All checks passed! Remote Podman engine is ready to use."
        echo
        echo "💡 Usage examples:"
        echo "   podman --remote ps"
        echo "   podman --remote run --rm hello-world"
        echo "   docker run --rm alpine echo 'Hello World!'"
    else
        print_error "❌ Some checks failed. Please review the errors above."
        echo
        echo "💡 Common solutions:"
        echo "   - Ensure Lima VM is running: limactl start $VM_NAME"
        echo "   - Rebuild VM configuration: lima $VM_NAME sudo nixos-rebuild switch"
        echo "   - Restart Podman service: lima $VM_NAME sudo systemctl restart podman.socket"
    fi
    
    return $failed
}

# Run main function
main "$@"
