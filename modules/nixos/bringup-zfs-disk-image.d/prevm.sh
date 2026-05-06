# shellcheck shell=bash disable=SC1091
# bringup-zfs-disk-image preVM — sets up Vector relay and disk images
#
# Runs on linux-builder before QEMU starts. Initializes:
#   - Vector relay (socat) forwarding nested QEMU events to local Vector agent
#   - Debug shell socket configuration for QEMU
#   - Boot and ZFS disk images (create new or copy from base)
#
# ENVIRONMENT:
#   NDH_VECTOR_ENDPOINT     — Vector endpoint (default: http://10.0.2.2:9001)
#   baseImagePath           — If set, copy existing disk images instead of creating new ones
#   bootDiskImage           — Boot disk filename
#   preVmDiskImageVars      — Shell assignments for ZFS disk image filenames
#   preVmCreateRawDisks     — Commands to create raw ZFS disk images
#   baseImageCopyCommands   — Commands to copy base image disks
#
# SUBSTITUTIONS (from Nix):
#   @socat@                 — Path to socat binary
#   @qemuBin@               — Path to qemu binary
#   @bringupCommon@         — Path to bringup-disk-image-common.sh

set -eo pipefail

PS4='[bringup-preVM:${LINENO}] '
set -x
PATH="$PATH:@qemuBin@"
mkdir "$out"

# ── Vector relay ──────────────────────────────────────────────────────────────
# Nested QEMU uses SLIRP user-net: 10.0.2.2 = linux-builder, not macOS.
# Relay: nested QEMU → linux-builder socat → linux-builder Vector agent → macOS aggregator.
# NDH_VECTOR_ENDPOINT injected via --impure-env; fallback to hardcoded default for testing.
export NDH_VECTOR_ENDPOINT="${NDH_VECTOR_ENDPOINT:-http://10.0.2.2:9001}"

: 'Connect to debug shell (Ctrl+] to disconnect):'
: '  sudo socat UNIX-CONNECT:/proc/$(pgrep --newest qemu)/cwd/shell.sock -,raw,echo=0,escape=0x1d'
:
: 'First thing after connecting — fix terminal size:'
: '  resize'
:
: 'Perf / debug tools available in the shell:'
: '  iostat -x 1              — per-disk utilisation, await, queue depth'
: '  mpstat -P ALL 1          — per-CPU breakdown'
: '  pidstat -d 1             — per-process I/O rates'
: '  iotop-c                  — live top-style I/O monitor'
: '  htop                     — CPU/mem/process overview'
: '  vmstat 1                 — memory pressure + block I/O summary'
: '  zpool iostat -v 1        — ZFS pool throughput'
: '  lsof                     — open files, sockets, ZFS handles'
: '  strace -p <pid>          — syscall trace on any process'

QEMU_OPTS+=" -device virtio-serial"
QEMU_OPTS+=" -chardev socket,id=shell-sock,path=$PWD/shell.sock,server=on,wait=off"
QEMU_OPTS+=" -device virtconsole,chardev=shell-sock,name=shell"

# Share xchg directory with nested QEMU via virtio-9p
mkdir -p "$PWD/xchg"
QEMU_OPTS+=" -fsdev local,id=fsdev-xchg,path=$PWD/xchg,security_model=none"
QEMU_OPTS+=" -device virtio-9p-pci,fsdev=fsdev-xchg,mount_tag=xchg"

source @bringupCommon@

bootDiskImage=boot.raw
@preVmDiskImageVars@
@baseImageLogic@
