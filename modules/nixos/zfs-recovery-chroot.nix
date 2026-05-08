{
  config,
  pkgs,
  lib,
  ...
}:

let
  zfsRecoveryChrootScript = pkgs.writeScriptBin "zfs-recovery-chroot" ''
    #!${pkgs.bash}/bin/bash
    # NixOS ZFS Recovery Chroot Script
    # Mounts ZFS datasets with altroot and sets up a chroot environment with network access
    # Designed to be run from a Debian rescue system

    set -euo pipefail

    # Configuration
    POOL_NAME="''${POOL_NAME:-tank}"
    DATASET_ROOT="''${DATASET_ROOT:-tank/nerd}"
    CHROOT_ROOT="''${CHROOT_ROOT:-/mnt/zfs-root}"
    PRESERVE_NETWORK="''${PRESERVE_NETWORK:-1}"

    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color

    log_info() {
        echo -e "''${GREEN}[INFO]''${NC} $*"
    }

    log_warn() {
        echo -e "''${YELLOW}[WARN]''${NC} $*"
    }

    log_error() {
        echo -e "''${RED}[ERROR]''${NC} $*"
    }

    check_root() {
        if [[ $EUID -ne 0 ]]; then
            log_error "This script must be run as root"
            exit 1
        fi
    }

    check_zfs() {
        if ! command -v zpool &> /dev/null; then
            log_error "ZFS utilities not found. Please install zfsutils-linux."
            log_error "On Debian/Ubuntu: apt-get install zfsutils-linux"
            exit 1
        fi
    }

    unmount_all() {
        log_info "Unmounting any existing ZFS datasets..."
        ${pkgs.zfs}/bin/zfs unmount -a 2>/dev/null || true
    }

    import_pool_with_altroot() {
        log_info "Checking if pool '$POOL_NAME' is already imported..."

        if ${pkgs.zfs}/bin/zpool list "$POOL_NAME" &>/dev/null; then
            log_warn "Pool '$POOL_NAME' already imported. Re-importing with altroot..."
            ${pkgs.zfs}/bin/zpool export "$POOL_NAME"
        fi

        log_info "Importing pool '$POOL_NAME' with altroot '$CHROOT_ROOT'..."
        ${pkgs.zfs}/bin/zpool import -f -R "$CHROOT_ROOT" "$POOL_NAME"

        log_info "Mounting all ZFS datasets..."
        ${pkgs.zfs}/bin/zfs mount -a
    }

    verify_mounts() {
        log_info "Verifying ZFS mounts:"
        ${pkgs.zfs}/bin/zfs list -r "$DATASET_ROOT" -o name,mountpoint,mounted | head -20
    }

    setup_network() {
        # Preserve network access
        if [[ "$PRESERVE_NETWORK" == "1" ]]; then
            log_info "Preserving network configuration..."

            # Backup existing resolv.conf if it exists
            if [[ -f "$CHROOT_ROOT/etc/resolv.conf" ]]; then
                cp "$CHROOT_ROOT/etc/resolv.conf" "$CHROOT_ROOT/etc/resolv.conf.backup"
            fi

            # Copy DNS configuration
            cp -L /etc/resolv.conf "$CHROOT_ROOT/etc/resolv.conf"

            # Optional: copy network configuration (commented out by default)
            # cp -L /etc/hosts "$CHROOT_ROOT/etc/hosts" 2>/dev/null || true
        fi
    }

    enter_chroot() {
        log_info "Entering NixOS environment using nixos-enter..."
        log_info "You are now in the NixOS environment at $CHROOT_ROOT"
        log_info "Network should be available. Type 'exit' to leave."
        echo ""

        # Use nixos-enter if available (it's in the NixOS store)
        # nixos-enter handles all the chroot setup including /proc, /sys, /dev mounts
        if command -v nixos-enter &>/dev/null; then
            nixos-enter --root "$CHROOT_ROOT"
        elif [[ -x "$CHROOT_ROOT/nix/var/nix/profiles/system/bin/nixos-enter" ]]; then
            "$CHROOT_ROOT/nix/var/nix/profiles/system/bin/nixos-enter" --root "$CHROOT_ROOT"
        else
            log_warn "nixos-enter not found, falling back to manual chroot setup..."
            # Fallback: manual chroot setup
            mkdir -p "$CHROOT_ROOT"/{proc,sys,dev,run,tmp}
            mount -t proc proc "$CHROOT_ROOT/proc" 2>/dev/null || true
            mount -t sysfs sys "$CHROOT_ROOT/sys" 2>/dev/null || true
            mount --rbind /dev "$CHROOT_ROOT/dev" 2>/dev/null || true
            mount --make-rslave "$CHROOT_ROOT/dev" 2>/dev/null || true

            # Enter chroot
            if [[ -f "$CHROOT_ROOT/run/current-system/sw/bin/bash" ]]; then
                chroot "$CHROOT_ROOT" /run/current-system/sw/bin/bash
            elif [[ -f "$CHROOT_ROOT/bin/bash" ]]; then
                chroot "$CHROOT_ROOT" /bin/bash
            else
                chroot "$CHROOT_ROOT" /bin/sh
            fi

            # Cleanup fallback mounts
            umount -l "$CHROOT_ROOT/dev" 2>/dev/null || true
            umount "$CHROOT_ROOT/proc" 2>/dev/null || true
            umount "$CHROOT_ROOT/sys" 2>/dev/null || true
        fi
    }

    cleanup_mounts() {
        log_info "Cleaning up mounts..."

        # Restore original resolv.conf
        if [[ -f "$CHROOT_ROOT/etc/resolv.conf.backup" ]]; then
            mv "$CHROOT_ROOT/etc/resolv.conf.backup" "$CHROOT_ROOT/etc/resolv.conf"
        fi

        log_info "Unmounting ZFS datasets..."
        ${pkgs.zfs}/bin/zfs unmount -a

        log_info "Exporting pool..."
        ${pkgs.zfs}/bin/zpool export "$POOL_NAME"

        log_info "Cleanup complete."
    }

    show_usage() {
        cat << EOF
    Usage: $0 [OPTIONS]

    Options:
        -p, --pool POOL         ZFS pool name (default: tank)
        -d, --dataset DATASET   Root dataset (default: tank/nerd)
        -r, --root PATH         Chroot root path (default: /mnt/zfs-root)
        -n, --no-network        Don't preserve network access
        -c, --cleanup           Only perform cleanup
        -h, --help              Show this help message

    Environment variables:
        POOL_NAME               ZFS pool name
        DATASET_ROOT            Root dataset
        CHROOT_ROOT             Chroot root path
        PRESERVE_NETWORK        Preserve network (1 or 0)

    Example:
        $0 --pool tank --dataset tank/nerd --root /mnt/zfs-root
    EOF
    }

    main() {
        local cleanup_only=0

        # Parse arguments
        while [[ $# -gt 0 ]]; do
            case $1 in
                -p|--pool)
                    POOL_NAME="$2"
                    shift 2
                    ;;
                -d|--dataset)
                    DATASET_ROOT="$2"
                    shift 2
                    ;;
                -r|--root)
                    CHROOT_ROOT="$2"
                    shift 2
                    ;;
                -n|--no-network)
                    PRESERVE_NETWORK=0
                    shift
                    ;;
                -c|--cleanup)
                    cleanup_only=1
                    shift
                    ;;
                -h|--help)
                    show_usage
                    exit 0
                    ;;
                *)
                    log_error "Unknown option: $1"
                    show_usage
                    exit 1
                    ;;
            esac
        done

        check_root
        check_zfs

        # Set up trap for cleanup on exit
        trap cleanup_mounts EXIT INT TERM

        if [[ $cleanup_only -eq 1 ]]; then
            cleanup_mounts
            trap - EXIT INT TERM
            exit 0
        fi

        unmount_all
        import_pool_with_altroot
        verify_mounts
        setup_network

        # Remove trap before entering chroot (we'll cleanup manually)
        trap - EXIT INT TERM

        enter_chroot

        # Cleanup after exiting chroot
        cleanup_mounts
    }

    main "$@"
  '';

in
{
  options = {
    zfsRecovery = {
      enable = lib.mkEnableOption "ZFS recovery chroot script";
    };
  };

  config = lib.mkIf config.zfsRecovery.enable {
    environment.systemPackages = [ zfsRecoveryChrootScript ];
  };
}
