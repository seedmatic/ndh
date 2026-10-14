# The operator's gestures on nerd-nixos's store stack (docs/store-freeze-spec.adoc).
#
#   ndh-store status                       the stack this boot was built on, the manifests, the upper's base
#   ndh-store freeze {validated system}    freeze the upper into a new layer, then reboot
#   ndh-store compact {validated system}   fold every layer above the EROFS ones into one, then reboot
#   ndh-store purge [--yes] {store path}…  rebuild the layers without those paths and their referrers
#   ndh-store confirm [--yes]              once booted on a new stack, destroy the layers it no longer names
#
# purge and confirm destroy data: without --yes they only list what they would do.
#
# Set by the wrapper: RW_DATASET, DB_DATASET, LAYERS_DATASET, RW_MOUNT, STACK_DIR, FROZEN_ROOT,
# EROFS_LOWERS, RUN_DIR, MANIFEST_VERSION, SWEEP_SHAPES, CONTAINER_PROJECT.

usage() {
  sed -n '3,9p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

die() {
  echo "ndh-store: $1" >&2
  exit 1
}

say() {
  echo "ndh-store: $1" >&2
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
      echo "$manifest: $(jq -c '{kind, layers: [.layers[].snapshot]}' "$STACK_DIR/$manifest.json" 2>/dev/null || echo unreadable)"
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

# preflight [{validated system}]: the refusals every gesture shares, then nix stopped. From here any
# exit before the reboot brings the builders back.
preflight() {
  local validated="${1:-}" current
  current=$(readlink -f /run/current-system)
  if [ -n "$validated" ] && [ "$current" != "$(readlink -f "$validated")" ]; then
    die "the current system is $current, not the validated $validated — nothing done"
  fi
  [ ! -e "$RUN_DIR/store-degraded" ] || die "this boot is degraded — repair it first"
  [ ! -e "$STACK_DIR/next.json" ] || die "a new stack is already pending in next.json — reboot first"

  # Delegated builds write into the upper: none may run, and none may start.
  if pgrep -u "$(getent group nixbld | cut -d: -f4)" >/dev/null 2>&1; then
    die "a build is running (a nixbld process) — nothing done"
  fi
  trap 'systemctl start nix-daemon.socket' EXIT
  systemctl stop nix-daemon.socket nix-daemon.service
  if [ -n "$(find /nix/var/nix/builds -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]; then
    die "a build dir is still in /nix/var/nix/builds — nothing done"
  fi
}

gc_and_verify() {
  say "GC to the GC roots"
  nix-store --gc || die "the GC failed — nothing done"
  say "every valid path must be present"
  nix-store --verify || die "nix-store --verify failed — nothing done"
}

# sweep {dir}: text and binary files alike. grep exits 0 on a match, 1 on none, 2 on an error: only 1
# is clean, since a sweep that could not run must never let a gesture make what it missed permanent.
sweep() {
  local hits status=0
  say "secret sweep of $1"
  hits=$(grep -rlE -f "$SWEEP_SHAPES" "$1") || status=$?
  case "$status" in
    0)
      say "a secret shape was found in:"
      printf '  %s\n' "$hits" >&2
      return 1
      ;;
    1) ;;
    *) die "the secret sweep could not run (grep exit $status) — nothing done" ;;
  esac
}

# base_layers: the committed current stack, which must be what the upper sits on — else the stack
# and the upper disagree, and nothing is done.
base_layers() {
  local base='[]'
  if [ -s "$STACK_DIR/current.json" ]; then base=$(jq -c '.layers' "$STACK_DIR/current.json"); fi
  if [ "$(jq -r '[.[].snapshot] | join(" ")' <<<"$base")" != "$(cat "$RW_MOUNT/upper.base" 2>/dev/null || true)" ]; then
    die "current.json is not what the upper sits on (upper.base) — nothing done"
  fi
  echo "$base"
}

# layer {dataset} {snapshot}: the manifest entry of a layer just snapshotted.
layer() {
  jq -cn --arg ds "$1" --arg s "$2" --arg g "$(zfs get -H -o value guid "$1@$2")" \
    '{dataset: $ds, snapshot: $s, guid: $g}'
}

# stage_next {kind} {layers} {base}: the next stack, built over the base, then the reboot that
# stacks it.
stage_next() {
  local kind="$1" layers="$2" base="$3" snapshot instance
  snapshot=$(jq -r '.[0].snapshot' <<<"$layers")
  write "$STACK_DIR/next.json" "$(jq -cn --arg v "$MANIFEST_VERSION" --arg k "$kind" \
    --arg sys "$(readlink -f /run/current-system)" --argjson layers "$layers" --argjson base "$base" \
    '{version: ($v | tonumber), kind: $k, layers: $layers, over: [$base[].snapshot], frozenFor: $sys}')"
  write "$STACK_DIR/request.json" "$(jq -cn --arg s "$snapshot" '{snapshot: $s}')"
  say "$kind staged as $snapshot; the next boot stacks it"

  if command -v incus >/dev/null; then
    for instance in $(incus list --project "$CONTAINER_PROJECT" -c n -f csv 2>/dev/null); do
      incus stop --project "$CONTAINER_PROJECT" "$instance"
    done
  fi
  # Not on the way down: the reboot stops everything anyway.
  trap - EXIT
  systemctl reboot
}

new_name() {
  echo "ndh-store-$(date -u +%Y%m%dT%H%M%SZ)"
}

# The layers above the EROFS ones, top first: the upper, then this boot's frozen layers.
upper_layers() {
  echo "$RW_MOUNT/upper"
  jq -r '.frozen[]' "$RUN_DIR/store-stack.json"
}

# top_of {name}: the directory of the layer above the EROFS ones that holds that store entry, or
# nothing when the EROFS layers hold it. A path spread over several layers is refused: copying its
# top alone would drop the rest.
top_of() {
  local name="$1" dir top="" lower
  while read -r dir; do
    if [ -e "$dir/$name" ] || [ -L "$dir/$name" ]; then
      top="$dir"
      break
    fi
  done < <(upper_layers)
  [ -n "$top" ] || return 0
  if [ -c "$top/$name" ]; then die "$name is valid but whited out in $top — nothing done"; fi
  if [ -d "$top/$name" ] && [ ! -L "$top/$name" ] &&
    [ "$(getfattr --absolute-names --only-values -n trusted.overlay.opaque "$top/$name" 2>/dev/null)" != "y" ]; then
    while read -r lower; do
      if [ "$lower" != "$top" ] && [ -d "$lower/$name" ]; then
        die "$name is spread over $top and $lower — nothing done"
      fi
    done < <(upper_layers | sed -n "\|^$top\$|,\$p"; tr ':' '\n' <<<"$EROFS_LOWERS")
  fi
  echo "$top"
}

# build_layer {name}: a new dataset holding every valid path the EROFS layers do not, copied from
# the layer that holds it — never through /nix/store, where copy_file_range does not clone the
# blocks (measured) — and a whiteout for every EROFS path that is no longer valid.
build_layer() {
  local name="$1" ds="$LAYERS_DATASET/$1" build="$RUN_DIR/build/$1" path entry top dir
  if ! zfs list -H "$LAYERS_DATASET" >/dev/null 2>&1; then
    zfs create -o canmount=off -o mountpoint=none "$LAYERS_DATASET"
  fi
  zfs create -o mountpoint=legacy "$ds"
  mkdir -p "$build"
  mount -t zfs "$ds" "$build"
  mkdir "$build/upper"
  chown --reference="$RW_MOUNT/upper" "$build/upper"
  chmod --reference="$RW_MOUNT/upper" "$build/upper"

  local -A valid
  while read -r path; do
    valid["${path#/nix/store/}"]=1
  done < <(nix-store --gc --print-live 2>/dev/null)
  [ "${#valid[@]}" -gt 0 ] || die "no valid path listed — nothing done"
  say "copying the valid paths the EROFS layers do not hold, out of ${#valid[@]}"
  for path in "${!valid[@]}"; do
    top=$(top_of "$path") || exit 1
    if [ -n "$top" ]; then
      cp -a --reflink=auto "$top/$path" "$build/upper/$path"
    fi
  done

  while read -r dir; do
    for entry in "$dir"/*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      entry="${entry##*/}"
      if [ -z "${valid[$entry]:-}" ] && [ ! -e "$build/upper/$entry" ]; then
        mknod "$build/upper/$entry" c 0 0
      fi
    done
  done < <(tr ':' '\n' <<<"$EROFS_LOWERS")
  sync
}

# seal_layer {name}: the built layer, read-only, snapshotted with the DB in one atomic snapshot.
seal_layer() {
  local name="$1" ds="$LAYERS_DATASET/$1"
  umount "$RUN_DIR/build/$name"
  zfs snapshot "$ds@$name" "$DB_DATASET@$name"
  zfs set readonly=on "$ds"
}

# drop_layer {name}: a layer built and refused, so the next attempt starts clean.
drop_layer() {
  umount "$RUN_DIR/build/$1" 2>/dev/null || true
  zfs destroy -r "$LAYERS_DATASET/$1"
}

# A freeze makes the upper PERMANENT: no GC ever frees a frozen path. So it runs only on the system
# the operator validated, with nix stopped, after a GC to the roots, a verify and a secret sweep —
# and a failure stops it before any snapshot.
freeze() {
  local base snapshot
  preflight "$1"
  gc_and_verify
  sweep "$RW_MOUNT/upper" || die "nothing frozen — purge those paths first"
  base=$(base_layers)
  snapshot=$(new_name)
  zfs snapshot "$RW_DATASET@$snapshot" "$DB_DATASET@$snapshot"
  stage_next freeze "$(jq -c --argjson new "$(layer "$RW_DATASET" "$snapshot")" '[$new] + .' <<<"$base")" "$base"
}

# A compaction keeps only the current generation, so it waits until that generation has booted:
# the previous one is the way back until then.
compact() {
  local base name
  [ "$(readlink -f /run/booted-system)" = "$(readlink -f /run/current-system)" ] ||
    die "the current system has not booted yet — reboot on it before compacting"
  preflight "$1"
  base=$(base_layers)
  say "keeping only the current generation"
  nix-env -p /nix/var/nix/profiles/system --delete-generations old || die "could not drop the old generations"
  /nix/var/nix/profiles/system/bin/switch-to-configuration boot || die "could not rewrite the bootloader"
  gc_and_verify
  name=$(new_name)
  build_layer "$name"
  if ! sweep "$RUN_DIR/build/$name/upper"; then
    drop_layer "$name"
    die "nothing compacted — purge those paths first"
  fi
  seal_layer "$name"
  stage_next compaction "[$(layer "$LAYERS_DATASET/$name" "$name")]" "$base"
}

# A purge removes the paths and the transitive closure of their referrers — nix assumes every valid
# path's references are valid — and rebuilds the layers without them. What it cannot reach is
# reported, never claimed.
purge() {
  local yes=false arg named=() closure roots member base name dir top
  if [ "${1:-}" = "--yes" ]; then
    yes=true
    shift
  fi
  [ "$#" -gt 0 ] || usage
  for arg in "$@"; do
    case "$arg" in
      /nix/store/*) named+=("/nix/store/$(cut -d/ -f4 <<<"$arg")") ;;
      *) die "$arg is not a store path" ;;
    esac
  done
  closure=$(nix-store --query --referrers-closure "${named[@]}" | sort -u) || die "could not query the referrers"
  roots=$(nix-store --gc --print-roots 2>/dev/null | sed 's|.* -> ||' | sort -u)
  say "the purge removes $(wc -l <<<"$closure") paths:"
  printf '  %s\n' "$closure" >&2

  while read -r member; do
    if grep -qxF "$member" <<<"$roots" && ! printf '%s\n' "${named[@]}" | grep -qxF "$member"; then
      die "$member is a GC root (a system, a profile, a container) — name it explicitly to purge it"
    fi
    top=$(top_of "${member#/nix/store/}") || exit 1
    [ -n "$top" ] || die "$member is in an EROFS layer — only an image rebuild removes it"
  done <<<"$closure"
  $yes || die "nothing purged — run again with --yes to purge those paths"

  preflight
  base=$(base_layers)
  # shellcheck disable=SC2086
  nix-store --delete --ignore-liveness $closure || die "could not unregister the paths — nothing purged"
  gc_and_verify
  name=$(new_name)
  build_layer "$name"
  while read -r member; do
    if [ -e "$RUN_DIR/build/$name/upper/${member#/nix/store/}" ] &&
      [ ! -c "$RUN_DIR/build/$name/upper/${member#/nix/store/}" ]; then
      drop_layer "$name"
      die "$member is still in the rebuilt layer — nothing purged"
    fi
  done <<<"$closure"
  if ! sweep "$RUN_DIR/build/$name/upper"; then
    drop_layer "$name"
    die "the rebuilt layer still holds a secret shape — purge those paths too"
  fi
  seal_layer "$name"
  say "NOT purged by this gesture, to report to 🛡️ as remaining actions:"
  say "  the containers' delivery snapshots and their own frozen layers"
  say "  the Macs' stores (a delegated build's output is copied back to the Mac)"
  say "  every binary cache the paths reached (attic, nxmatic.cachix if a watch-store ran)"
  say "  the old layers, until \`ndh-store confirm --yes\` after this reboot"
  stage_next purge "[$(layer "$LAYERS_DATASET/$name" "$name")]" "$base"
}

# Once booted on the stack current.json names, the layers no other manifest needs are destroyed:
# their bytes leave the pool, and previous.json, which names them, goes with them.
confirm() {
  local yes=false keep obsolete
  [ "${1:-}" != "--yes" ] || yes=true
  [ ! -e "$RUN_DIR/store-degraded" ] || die "this boot is degraded — repair it first"
  [ ! -e "$STACK_DIR/next.json" ] || die "a new stack is pending in next.json — reboot first"
  [ -s "$STACK_DIR/current.json" ] || die "no current stack"
  keep=$(jq -r '.layers[].snapshot' "$STACK_DIR/current.json")
  [ "$(jq -r '.frozen | map(split("/")[-2]) | join(" ")' "$RUN_DIR/store-stack.json")" = "$(paste -sd' ' <<<"$keep")" ] ||
    die "this boot is not on current.json's stack — reboot on it first"
  # Only the stack's own names: the containers' delivery snapshots are theirs.
  obsolete=$({
    zfs list -H -t snapshot -o name "$RW_DATASET" "$DB_DATASET"
    zfs list -H -d 1 -t filesystem -o name "$LAYERS_DATASET" 2>/dev/null || true
  } | grep -E '[@/]ndh-store-[0-9]{8}T[0-9]{6}Z$' | while read -r ds; do
    if ! grep -qxF "${ds##*[@/]}" <<<"$keep"; then echo "$ds"; fi
  done)
  if [ -z "$obsolete" ]; then
    say "no layer to release"
    return
  fi
  say "destroying the layers current.json no longer names:"
  printf '  %s\n' "$obsolete" >&2
  $yes || die "nothing destroyed — run again with --yes"
  while read -r ds; do
    zfs destroy -r "$ds"
  done <<<"$obsolete"
  if [ -e "$STACK_DIR/previous.json" ]; then rm "$STACK_DIR/previous.json"; fi
  say "released; the way back is now this stack only"
}

case "${1:-}" in
  status) status ;;
  freeze | compact)
    [ -n "${2:-}" ] || usage
    "$1" "$2"
    ;;
  purge)
    shift
    purge "$@"
    ;;
  confirm) confirm "${2:-}" ;;
  *) usage ;;
esac
