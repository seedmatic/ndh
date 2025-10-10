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

cmd="${CIDATA_MNT}/lima-guestagent daemon"

if [[ -n "${DEBUG_FLAG}" ]]; then
  cmd+=" --debug=${DEBUG_FLAG}"
fi

if [[ -n "${VIRTIO_PORT}" && "${VIRTIO_PORT}" != "0" ]]; then
  cmd+=" --virtio-port=${VIRTIO_PORT}"
fi

if [[ -n "${VSOCK_PORT}" && "${VSOCK_PORT}" != "0" && -e /dev/vsock ]]; then
  cmd+=" --vsock-port=${VSOCK_PORT}"
fi

exec ${cmd}
