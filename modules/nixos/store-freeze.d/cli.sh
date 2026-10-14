# The operator's gestures on nerd-nixos's store stack (docs/store-freeze-spec.adoc).
#
#   ndh-store status   the stack this boot was built on, the manifests, what the upper sits on
#
# Set by the wrapper: RW_DATASET, DB_DATASET, RW_MOUNT, STACK_DIR, FROZEN_ROOT, EROFS_LOWERS,
# RUN_DIR, MANIFEST_VERSION.

usage() {
  sed -n '3,4p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

status() {
  local manifest
  if [ -s "$RUN_DIR/store-stack.json" ]; then
    echo "this boot: $(jq -c '{manifest, frozen}' "$RUN_DIR/store-stack.json")"
  else
    echo "this boot: no stack description from the initrd"
  fi
  if [ -e "$RUN_DIR/store-degraded" ]; then echo "DEGRADED: $(cat "$RUN_DIR/store-degraded")"; fi
  if [ -e "$RUN_DIR/store-freeze-not-done" ]; then
    echo "a requested freeze is not in this stack: $(cat "$RUN_DIR/store-freeze-not-done")"
  fi
  for manifest in next current previous; do
    if [ -e "$STACK_DIR/$manifest.json" ]; then
      echo "$manifest: $(jq -c '[.layers[].snapshot]' "$STACK_DIR/$manifest.json")"
    fi
  done
  if [ -s "$RW_MOUNT/upper.base" ]; then
    echo "the upper sits on: $(cat "$RW_MOUNT/upper.base")"
  else
    echo "the upper sits on: the bare EROFS layers"
  fi
}

case "${1:-}" in
  status) status ;;
  *) usage ;;
esac
