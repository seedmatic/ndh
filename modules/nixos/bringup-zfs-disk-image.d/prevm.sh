# shellcheck shell=bash disable=SC1091
# bringup-zfs-disk-image preVM - sets up Vector relay and disk images
#
# Runs on linux-builder before QEMU starts. Initializes:
#   - Vector relay (socat) forwarding nested QEMU events to local Vector agent
#   - Debug shell socket configuration for QEMU
#   - Boot and ZFS disk images (always creates fresh blank disks)
#
# ENVIRONMENT:
#   NDH_VECTOR_ENDPOINT       - Vector endpoint (baked in: http://10.0.2.2:9001)
#   NDH_NIXOS_NAME            - Short hostname label for logging
#   NDH_BRINGUP_COMMON_SCRIPT - Path to bringup-disk-image-common.sh
#   NDH_BOOT_DISK_SIZE        - Boot disk size in MiB
#   (ZFS disk vars set by wrapper: tankDiskImage, recoverDiskImage, etc.)

set -eo pipefail

PS4="[${NDH_NIXOS_NAME:-nixos}:bringup-preVM:\${LINENO}] "
set -x
mkdir "$out"

# -- Vector relay --
# Nested QEMU uses SLIRP user-net: 10.0.2.2 = linux-builder, not macOS.
# Relay: nested QEMU -> linux-builder socat -> linux-builder Vector agent -> macOS aggregator.
# Endpoint is topology-fixed; baked in as default (no impure-env needed).
export NDH_VECTOR_ENDPOINT="${NDH_VECTOR_ENDPOINT:-http://10.0.2.2:9001}"

: 'Connect to debug shell (Ctrl+] to disconnect):'
: '  sudo socat UNIX-CONNECT:/proc/$(pgrep --newest qemu)/cwd/shell.sock -,raw,echo=0,escape=0x1d'
:
: 'First thing after connecting - fix terminal size:'
: '  resize'
:
: 'Perf / debug tools available in the shell:'
: '  iostat -x 1         - per-disk utilisation, await, queue depth'
: '  mpstat -P ALL 1     - per-CPU breakdown'
: '  pidstat -d 1        - per-process I/O rates'
: '  iotop-c             - live top-style I/O monitor'
: '  htop                - CPU/mem/process overview'
: '  vmstat 1            - memory pressure + block I/O summary'
: '  zpool iostat -v 1   - ZFS pool throughput'
: '  lsof                - open files, sockets, ZFS handles'
: '  strace -p <pid>     - syscall trace on any process'

QEMU_OPTS+=" -device virtio-serial"
QEMU_OPTS+=" -chardev socket,id=shell-sock,path=$PWD/shell.sock,server=on,wait=off"
QEMU_OPTS+=" -device virtconsole,chardev=shell-sock,name=shell"

# A failed install leaves its trace only in xchg/install.log, inside a build directory nix removes, and
# postVM never runs after a failure: then say the end of that log in the build log. Its lines are the
# install's own trace — paths and verdicts; the secret-material guard prints no file content. A build
# log persists (`nix log`) and travels, so the lines are MASKED on the way: an age secret, and every
# line between a private-key header and its footer, whatever a future change makes the install print
# (install-log-mask.sed, whose check is bringup-install-log-mask).
ndh_bringup_install_log_on_failure() {
  local rc=$?
  if [ "$rc" != 0 ] && [ -f xchg/install.log ]; then
    echo "[bringup] the install failed (rc=$rc); the end of its log (masked):" >&2
    # Masked BEFORE the cut: a window that starts inside a key would leave its header above the cut,
    # and a header-bound rule would never open.
    sed -E -f "$NDH_INSTALL_LOG_MASK" xchg/install.log | tail -n 60 >&2
  fi
}
trap ndh_bringup_install_log_on_failure EXIT

# Share xchg directory with nested QEMU via virtio-9p
mkdir -p "$PWD/xchg"
QEMU_OPTS+=" -fsdev local,id=fsdev-xchg,path=$PWD/xchg,security_model=none"
QEMU_OPTS+=" -device virtio-9p-pci,fsdev=fsdev-xchg,mount_tag=xchg"

# shellcheck disable=SC1090
source "${NDH_BRINGUP_COMMON_SCRIPT}"

# Disk image vars and creation are done by the Nix wrapper before calling this script
# (exported as: bootDiskImage, tankDiskImage, recoverDiskImage, NDH_BOOT_DISK_SIZE, etc.)
# The bringup::create_raw_disk calls happen in the preVM phase of the Nix derivation.
