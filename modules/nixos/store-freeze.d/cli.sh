# The operator's gestures on nerd-nixos's store stack (docs/store-freeze-spec.adoc).
#
#   ndh-store status                    the stack this boot was built on, the manifests, the upper's base
#   ndh-store freeze {validated system}  freeze the upper into a new layer, then reboot
#
# Set by the wrapper: RW_DATASET, DB_DATASET, RW_MOUNT, STACK_DIR, FROZEN_ROOT, EROFS_LOWERS,
# RUN_DIR, MANIFEST_VERSION, SWEEP_SHAPES, CONTAINER_PROJECT.

usage() {
  sed -n '3,5p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

die() {
  echo "ndh-store: $1" >&2
  exit 1
}

status() {
  local manifest
  if [ -s "$RUN_DIR/store-stack.json" ]; then
    echo "this boot: $(jq -c '{manifest, frozen}' "$RUN_DIR/store-stack.json")"
  else
    echo "this boot: no stack description from the initrd"
  fi
  if [ -e "$RUN_DIR/store-degraded" ]; then echo "DEGRADED: $(cat "$RUN_DIR/store-degraded")"; fi
  if [ -e "$RUN_DIR/store-manifest-refused" ]; then echo "REFUSED: $(cat "$RUN_DIR/store-manifest-refused")"; fi
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

# write {path} {content}: temporary file, rename, then fsync of the directory.
write() {
  printf '%s\n' "$2" >"$1.tmp"
  sync "$1.tmp"
  mv "$1.tmp" "$1"
  sync "$(dirname "$1")"
}

# A freeze makes the upper PERMANENT: no GC ever frees a frozen path. So it runs only on the system
# the operator validated, with nix stopped, after a GC to the roots, a verify and a secret sweep —
# and a failure stops it before any snapshot.
freeze() {
  local validated="$1" current snapshot guid base hits instance next
  current=$(readlink -f /run/current-system)
  [ "$current" = "$(readlink -f "$validated")" ] ||
    die "the current system is $current, not the validated $validated — nothing frozen"
  [ ! -e "$RUN_DIR/store-degraded" ] || die "this boot is degraded — repair it before freezing"
  [ ! -e "$STACK_DIR/next.json" ] || die "a freeze is already pending in next.json — reboot first"

  # Delegated builds write into the upper: none may run, and none may start.
  if pgrep -u "$(getent group nixbld | cut -d: -f4)" >/dev/null 2>&1; then
    die "a build is running (a nixbld process) — nothing frozen"
  fi
  # From here any exit before the reboot brings the builders back.
  trap 'systemctl start nix-daemon.socket' EXIT
  systemctl stop nix-daemon.socket nix-daemon.service
  if [ -n "$(find /nix/var/nix/builds -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]; then
    die "a build dir is still in /nix/var/nix/builds — nothing frozen"
  fi

  echo "ndh-store: GC of the upper to the GC roots" >&2
  nix-store --gc || die "the GC failed — nothing frozen"
  echo "ndh-store: every valid path must be present" >&2
  nix-store --verify || die "nix-store --verify failed — nothing frozen"

  # Text and binary files alike. grep exits 0 on a match, 1 on none, 2 on an error: only 1 is clean,
  # since a sweep that could not run must never let a freeze make what it missed permanent.
  echo "ndh-store: secret sweep of the upper" >&2
  local sweep=0
  hits=$(grep -rlE -f "$SWEEP_SHAPES" "$RW_MOUNT/upper") || sweep=$?
  case "$sweep" in
    0)
      echo "ndh-store: a secret shape was found in:" >&2
      printf '  %s\n' "$hits" >&2
      die "nothing frozen — purge those paths first"
      ;;
    1) ;;
    *) die "the secret sweep could not run (grep exit $sweep) — nothing frozen" ;;
  esac

  snapshot="ndh-store-$(date -u +%Y%m%dT%H%M%SZ)"
  zfs snapshot "$RW_DATASET@$snapshot" "$DB_DATASET@$snapshot"
  guid=$(zfs get -H -o value guid "$RW_DATASET@$snapshot")

  # The next stack: the new layer on top of the committed current one, which must be what the
  # upper sits on — else the stack and the upper disagree, and nothing is frozen.
  base='[]'
  if [ -s "$STACK_DIR/current.json" ]; then base=$(jq -c '.layers' "$STACK_DIR/current.json"); fi
  if [ "$(jq -r '[.[].snapshot] | join(" ")' <<<"$base")" != "$(cat "$RW_MOUNT/upper.base" 2>/dev/null || true)" ]; then
    zfs destroy "$RW_DATASET@$snapshot"
    zfs destroy "$DB_DATASET@$snapshot"
    die "current.json is not what the upper sits on (upper.base) — nothing frozen"
  fi
  next=$(jq -cn --arg v "$MANIFEST_VERSION" --arg ds "$RW_DATASET" --arg s "$snapshot" --arg g "$guid" \
    --arg sys "$current" --argjson base "$base" \
    '{version: ($v | tonumber), layers: ([{dataset: $ds, snapshot: $s, guid: $g}] + $base), frozenFor: $sys}')
  write "$STACK_DIR/next.json" "$next"
  write "$STACK_DIR/request.json" "$(jq -cn --arg s "$snapshot" '{snapshot: $s}')"
  echo "ndh-store: frozen as $snapshot; the next boot stacks it" >&2

  if command -v incus >/dev/null; then
    for instance in $(incus list --project "$CONTAINER_PROJECT" -c n -f csv 2>/dev/null); do
      incus stop --project "$CONTAINER_PROJECT" "$instance"
    done
  fi
  # Not on the way down: the reboot stops everything anyway.
  trap - EXIT
  systemctl reboot
}

case "${1:-}" in
  status) status ;;
  freeze)
    [ -n "${2:-}" ] || usage
    freeze "$2"
    ;;
  *) usage ;;
esac
