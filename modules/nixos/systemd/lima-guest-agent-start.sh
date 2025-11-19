#!/usr/bin/env bash
set -euxo pipefail

CIDATA_MNT=${CIDATA_MNT:-/mnt/lima-cidata}

if [[ -f "${CIDATA_MNT}/lima.env" ]]; then
  set -a
  # Use yq to properly parse lima.env (handles values with spaces like "Stephane Lacoin")
  # SC1090: dynamic source path; SC1091: file not known at build time (provided at runtime by lima cidata)
  source <( yq --input-format=props --output-format=shell "${CIDATA_MNT}/lima.env" )
  set +a
fi

DEBUG_FLAG=${LIMA_CIDATA_DEBUG:-}
VIRTIO_PORT=${LIMA_CIDATA_VIRTIO_PORT:-}
VSOCK_PORT=${LIMA_CIDATA_VSOCK_PORT:-}

# Build command as an array to handle arguments properly
cmd_args=("${CIDATA_MNT}/lima-guestagent" "daemon")

if [[ -n "${DEBUG_FLAG}" ]]; then
  cmd_args+=("--debug=${DEBUG_FLAG}")
fi

if [[ -n "${VIRTIO_PORT}" && "${VIRTIO_PORT}" != "0" ]]; then
  cmd_args+=("--virtio-port=${VIRTIO_PORT}")
fi

if [[ -n "${VSOCK_PORT}" && "${VSOCK_PORT}" != "0" && -e /dev/vsock ]]; then
  cmd_args+=("--vsock-port=${VSOCK_PORT}")
fi

# Use nix-ld to run the dynamically linked binary
# Detect architecture for the correct dynamic linker
case "$(uname -m)" in
  x86_64)
    NIX_LD_NAME="ld-linux-x86-64.so.2"
    ;;
  aarch64)
    NIX_LD_NAME="ld-linux-aarch64.so.1"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

NIX_LD_PATH="/run/current-system/sw/share/nix-ld/lib/${NIX_LD_NAME}"

if [[ -f "${NIX_LD_PATH}" ]]; then
  export NIX_LD="${NIX_LD_PATH}"
  export NIX_LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib
  exec "${NIX_LD}" "${cmd_args[@]}"
else
  exec "${cmd_args[@]}"
fi
