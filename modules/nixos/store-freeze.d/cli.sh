# The operator's gestures on nerd-nixos's store stack (docs/store-freeze-spec.adoc).
#
#   ndh-store status                       the stack this boot was built on, the manifests, the upper's base
#   ndh-store freeze [--accept {store path}]… {validated system}
#                                          freeze the upper into a new layer, then reboot
#   ndh-store compact [--accept {store path}]… {validated system}
#                                          fold every layer above the EROFS ones into one, then reboot
#   ndh-store purge [--yes] {store path}…  rebuild the layers without those paths and their referrers
#   ndh-store confirm [--yes]              once booted on a new stack, destroy the layers it no longer names
#
# purge and confirm destroy data: without --yes they only list what they would do. --accept lets a
# path the secret sweep refuses through, bound to its narHash: for a public one only.
#
# Every refusal comes before the first change: the sweep reads what the new layer would hold before a
# generation, the bootloader or the GC is touched, so a refused gesture leaves the machine as it was.
#
# Set by the wrapper: RW_DATASET, DB_DATASET, LAYERS_DATASET, RW_MOUNT, STACK_DIR, FROZEN_ROOT,
# EROFS_LOWERS, RUN_DIR, MANIFEST_VERSION, SWEEP_SHAPES, CONTAINER_PROJECT, CONTAINER_STATE_ROOT,
# SYSTEM_PROFILE, CURRENT_SYSTEM, BOOTED_SYSTEM, NIX_BUILDS_DIR, INCUS_ENABLED.

usage() {
  # By its content, not its line numbers: the wrapper puts its own lines before this file.
  sed -n '/^#   ndh-store /,/^#$/p' "${BASH_SOURCE[0]}" | sed '$d' >&2
  exit 2
}

die() {
  echo "ndh-store: $1" >&2
  exit 1
}

say() {
  echo "ndh-store: $1" >&2
}

# listing {lines}: one indented line each, on stderr.
listing() {
  local line
  while IFS= read -r line; do echo "  $line" >&2; done <<<"$1"
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

# The layer being built, until it is sealed: any exit before that drops it.
BUILDING=""

# On every exit before the reboot: an unsealed layer is dropped, its mount point too, and nix comes back.
cleanup() {
  if [ -n "$BUILDING" ]; then drop_layer "$BUILDING"; fi
  systemctl start nix-daemon.socket
}

# preflight [{validated system}]: the refusals every gesture shares, then nix stopped. From here any
# exit before the reboot brings the builders back.
preflight() {
  local validated="${1:-}" current
  current=$(readlink -f "$CURRENT_SYSTEM")
  if [ -n "$validated" ] && [ "$current" != "$(readlink -f "$validated")" ]; then
    die "the current system is $current, not the validated $validated — nothing done"
  fi
  [ ! -e "$RUN_DIR/store-degraded" ] || die "this boot is degraded — repair it first"
  [ ! -e "$STACK_DIR/next.json" ] || die "a new stack is already pending in next.json — reboot first"
  # With Incus on, the containers are stopped before the reboot: a missing incus must refuse, never skip that.
  if [ "$INCUS_ENABLED" = true ]; then
    command -v incus >/dev/null || die "Incus is enabled but incus is not on this program's path — nothing done"
  fi

  # Delegated builds write into the upper: none may run, and none may start.
  if pgrep -u "$(getent group nixbld | cut -d: -f4)" >/dev/null 2>&1; then
    die "a build is running (a nixbld process) — nothing done"
  fi
  trap cleanup EXIT
  systemctl stop nix-daemon.socket nix-daemon.service
  if [ -n "$(find "$NIX_BUILDS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]; then
    die "a build dir is still in /nix/var/nix/builds — nothing done"
  fi
}

# Before any change: a store that does not verify is repaired first, never frozen nor folded.
verify_first() {
  say "every valid path must be present"
  nix-store --verify || die "nix-store --verify failed — nothing done"
}

gc_and_verify() {
  say "GC to the GC roots"
  nix-store --gc || die "the GC failed"
  nix-store --verify || die "nix-store --verify failed after the GC"
}

# entries_of {live paths}: each one's entry in the layer above the EROFS ones that holds it.
entries_of() {
  local path top
  while read -r path; do
    [ -n "$path" ] || continue
    top=$(top_of "${path#/nix/store/}") || exit 1
    if [ -n "$top" ]; then echo "$top/${path#/nix/store/}"; fi
  done <<<"$1"
}

# sweep {valid paths} {entries}: the entries that hold a secret shape, text and binary files alike, the
# valid paths being the store as it will be.
#
# Its scope is every entry that is NOT a built output: paths with no deriver (sources, eval copies,
# `nix-store --add`), outputs whose .drv is not in this store, every .drv, and anything invalid —
# the leak class of 2026-10-10. A built
# output is public; a secret interpolated into it at evaluation sits in its .drv, which
# keep-derivations keeps and this sweeps (🛡️, 2026-10-14). A hit passes only if the operator
# accepted it, bound to its narHash. grep exits 0 on a match, 1 on none, 2 on an error: only 1 is
# clean, since a sweep that could not run must never let a gesture make what it missed permanent.
# It reports store paths only, never a matching line: the line would be the secret.
sweep() {
  local valid="$1" entries="$2" entry name status derivers missing hits="" refused="" accepted="" hash
  local -A built=() absent=()
  say "secret sweep of $(grep -c . <<<"$entries" || true) entries (every one but built outputs)"
  derivers=$(xargs -r nix-store -q --deriver <<<"$valid") || die "cannot query the derivers — nothing done"
  # A recorded deriver is not enough: a SUBSTITUTED output carries its deriver's name in the
  # narinfo while that .drv was never instantiated here, so nothing would sweep it. An output is
  # exempt only when its .drv is valid in this store (🛡️, review of 0e5fb7a9).
  missing=$({ grep -vx unknown-deriver <<<"$derivers" || true; } | sort -u | xargs -r nix-store --check-validity --print-invalid) ||
    die "cannot check the derivers — nothing done"
  while read -r name; do
    if [ -n "$name" ]; then absent["$name"]=1; fi
  done <<<"$missing"
  while read -r entry name; do
    if [ "$name" != unknown-deriver ] && [ -z "${absent[$name]:-}" ]; then built["${entry#/nix/store/}"]=1; fi
  done < <(paste -d' ' <(echo "$valid") <(echo "$derivers"))
  while read -r entry; do
    [ -n "$entry" ] || continue
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="${entry##*/}"
    [ -z "${built[$name]:-}" ] || continue
    status=0
    grep -rqE -f "$SWEEP_SHAPES" "$entry" || status=$?
    case "$status" in
      0) hits+="${hits:+$'\n'}$name" ;;
      1) ;;
      *) die "the secret sweep could not run (grep exit $status on $name) — nothing done" ;;
    esac
  done <<<"$entries"
  while read -r name; do
    [ -n "$name" ] || continue
    hash=$(nix-store -q --hash "/nix/store/$name" 2>/dev/null || true)
    if [ -n "$hash" ] && grep -qxF "$name $hash" "$STACK_DIR/accepted" 2>/dev/null; then
      accepted+="${accepted:+$'\n'}/nix/store/$name"
    else
      refused+="${refused:+$'\n'}/nix/store/$name"
    fi
  done <<<"$hits"
  if [ -n "$accepted" ]; then
    say "$(wc -l <<<"$accepted") paths hold a secret shape and were ACCEPTED, bound to their narHash:"
    listing "$accepted"
  fi
  if [ -n "$refused" ]; then
    say "$(wc -l <<<"$refused") paths hold a secret shape:"
    listing "$refused"
    say "purge them, or, for a PUBLIC one only: ndh-store freeze --accept {store path} …"
    say "NEVER accept a -source copy of OUR repositories (rke2lab, ndh, nnh and their subtrees): purge it"
    return 1
  fi
  if [ -n "$accepted" ]; then
    say "secret sweep: nothing refused"
  else
    say "secret sweep clean"
  fi
}

# accepts {args}: the leading --accept pairs, kept in ACCEPTS, not yet recorded; ACCEPTED_SHIFT says how many
# args they took.
ACCEPTS=()
accepts() {
  ACCEPTED_SHIFT=0
  while [ "${1:-}" = --accept ]; do
    [ -n "${2:-}" ] || usage
    ACCEPTS+=("$2")
    shift 2
    ACCEPTED_SHIFT=$((ACCEPTED_SHIFT + 2))
  done
}

# record_accepts: the acceptances, recorded just before the sweep that reads them, so a gesture refused for
# another reason leaves none on disk (🛡️).
record_accepts() {
  local path
  for path in "${ACCEPTS[@]}"; do accept "$path"; done
}

# accept {store path}: let one path the sweep refuses through, recorded with its narHash, so the
# same name with other content is refused again.
accept() {
  local path hash name
  [[ "$1" == /nix/store/* ]] || die "$1 is not a store path"
  path="/nix/store/$(cut -d/ -f4 <<<"$1")"
  hash=$(nix-store -q --hash "$path") || die "$path is not a valid store path — it cannot be accepted"
  name="${path#/nix/store/}"
  touch "$STACK_DIR/accepted"
  grep -v "^$name " "$STACK_DIR/accepted" >"$STACK_DIR/accepted.tmp" || true
  echo "$name $hash" >>"$STACK_DIR/accepted.tmp"
  sync "$STACK_DIR/accepted.tmp"
  mv "$STACK_DIR/accepted.tmp" "$STACK_DIR/accepted"
  say "accepted $path, bound to $hash"
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
    --arg sys "$(readlink -f "$CURRENT_SYSTEM")" --argjson layers "$layers" --argjson base "$base" \
    '{version: ($v | tonumber), kind: $k, layers: $layers, over: [$base[].snapshot], frozenFor: $sys}')"
  write "$STACK_DIR/request.json" "$(jq -cn --arg s "$snapshot" '{snapshot: $s}')"
  say "$kind staged as $snapshot; the next boot stacks it"

  if [ "$INCUS_ENABLED" = true ]; then
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
  local name="$1" dir top="" lower layers below seen=false
  # Captured, never read through a process substitution: a tool failing there would skip the check silently.
  layers=$(upper_layers) || die "cannot list the layers above the EROFS ones — nothing done"
  while read -r dir; do
    if [ -e "$dir/$name" ] || [ -L "$dir/$name" ]; then
      top="$dir"
      break
    fi
  done <<<"$layers"
  [ -n "$top" ] || return 0
  if [ -c "$top/$name" ]; then die "$name is valid but whited out in $top — nothing done"; fi
  if [ -d "$top/$name" ] && [ ! -L "$top/$name" ] &&
    [ "$(getfattr --absolute-names --only-values -n trusted.overlay.opaque "$top/$name" 2>/dev/null)" != "y" ]; then
    # The layers from the top one down, then the EROFS ones.
    below=""
    while read -r dir; do
      if [ "$dir" = "$top" ]; then seen=true; fi
      if $seen; then below+="$dir"$'\n'; fi
    done <<<"$layers"
    below+="${EROFS_LOWERS//:/$'\n'}"
    while read -r lower; do
      if [ -n "$lower" ] && [ "$lower" != "$top" ] && [ -d "$lower/$name" ]; then
        die "$name is spread over $top and $lower — nothing done"
      fi
    done <<<"$below"
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
  BUILDING="$name"
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
  BUILDING=""
  rmdir "$RUN_DIR/build/$name"
}

# drop_layer {name}: a layer built and not sealed, so the next attempt starts clean.
drop_layer() {
  umount "$RUN_DIR/build/$1" 2>/dev/null || true
  zfs destroy -r "$LAYERS_DATASET/$1"
  BUILDING=""
  rmdir "$RUN_DIR/build/$1" 2>/dev/null || true
}

# A freeze makes the upper PERMANENT: no GC ever frees a frozen path. So it runs only on the system
# the operator validated, with nix stopped, after a GC to the roots, a verify and a secret sweep —
# and a failure stops it before any snapshot.
freeze() {
  local base snapshot valid entry entries=""
  accepts "$@"
  shift "$ACCEPTED_SHIFT"
  [ -n "${1:-}" ] || usage
  preflight "$1"
  base=$(base_layers)
  verify_first
  valid=$(nix-store --gc --print-live 2>/dev/null) || die "cannot list the valid paths — nothing done"
  while read -r entry; do
    if [ -n "$entry" ] && { [ -e "$RW_MOUNT/upper/${entry#/nix/store/}" ] || [ -L "$RW_MOUNT/upper/${entry#/nix/store/}" ]; }; then
      entries+="${entries:+$'\n'}$RW_MOUNT/upper/${entry#/nix/store/}"
    fi
  done <<<"$valid"
  record_accepts
  sweep "$valid" "$entries" || die "nothing frozen — purge those paths first"
  gc_and_verify
  snapshot=$(new_name)
  zfs snapshot "$RW_DATASET@$snapshot" "$DB_DATASET@$snapshot"
  stage_next freeze "$(jq -c --argjson new "$(layer "$RW_DATASET" "$snapshot")" '[$new] + .' <<<"$base")" "$base"
}

# A compaction keeps only the current generation, so it waits until that generation has booted:
# the previous one is the way back until then.
compact() {
  local base name valid entries
  accepts "$@"
  shift "$ACCEPTED_SHIFT"
  [ -n "${1:-}" ] || usage
  [ "$(readlink -f "$BOOTED_SYSTEM")" = "$(readlink -f "$CURRENT_SYSTEM")" ] ||
    die "the current system has not booted yet — reboot on it before compacting"
  preflight "$1"
  base=$(base_layers)
  verify_first
  # Today's live set, a superset of what the compaction keeps: computing the kept set exactly would have
  # to replay the GC's keep-derivations and keep-outputs, and a miss would fold an unswept path in. A
  # path only an old generation holds is swept too: --accept it or purge it.
  valid=$(nix-store --gc --print-live 2>/dev/null) || die "cannot list the valid paths — nothing done"
  # Captured first: a refusal inside a command substitution would not stop the sweep.
  entries=$(entries_of "$valid") || exit 1
  record_accepts
  sweep "$valid" "$entries" || die "nothing compacted — purge those paths, or --accept a public one"
  say "keeping only the current generation"
  nix-env -p "$SYSTEM_PROFILE" --delete-generations old || die "could not drop the old generations"
  "$SYSTEM_PROFILE/bin/switch-to-configuration" boot || die "could not rewrite the bootloader"
  gc_and_verify
  name=$(new_name)
  build_layer "$name"
  seal_layer "$name"
  stage_next compaction "[$(layer "$LAYERS_DATASET/$name" "$name")]" "$base"
}

# A purge removes the paths and the transitive closure of their referrers — nix assumes every valid
# path's references are valid — and rebuilds the layers without them. What it cannot reach is
# reported, never claimed.
purge() {
  local yes=false arg named=() closure roots member base name top valid entries
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
  local listed line
  listed=$(nix-store --gc --print-roots 2>/dev/null) || die "cannot list the GC roots — nothing purged"
  roots=$(while read -r line; do if [ -n "$line" ]; then echo "${line##* -> }"; fi; done <<<"$listed" | sort -u)
  say "the purge removes $(wc -l <<<"$closure") paths:"
  listing "$closure"

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
  verify_first
  valid=$(nix-store --gc --print-live 2>/dev/null | grep -vxF -f <(echo "$closure")) ||
    die "cannot list the valid paths — nothing purged"
  entries=$(entries_of "$valid") || exit 1
  sweep "$valid" "$entries" || die "the layers left would still hold a secret shape — purge those paths too"
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
  seal_layer "$name"
  say "NOT purged by this gesture, to report to 🛡️ as remaining actions:"
  say "  the containers' delivery snapshots and their own frozen layers"
  say "  the Macs' stores (a delegated build's output is copied back to the Mac)"
  say "  every binary cache the paths reached (each metalspace's attic)"
  say "  the old layers, until \`ndh-store confirm --yes\` after this reboot"
  say "  the host's disk image and its SSD, even after confirm: a purge is hygiene, not erasure —"
  say "  if these paths held a secret, ROTATE it"
  stage_next purge "[$(layer "$LAYERS_DATASET/$name" "$name")]" "$base"
}

# Once booted on the stack current.json names, the layers no other manifest needs are destroyed, and
# previous.json, which names them, goes with them. Their blocks leave the pool's allocation, then a
# trim clears them from the guest's disks; below that, a sparse host image does not rewrite what a
# discard drops, and an SSD keeps its old cells (measured on the probe, 2026-10-14). So this is
# hygiene: a secret that was frozen is rotated, whatever this did.
confirm() {
  local yes=false keep listed obsolete ds
  [ "${1:-}" != "--yes" ] || yes=true
  [ ! -e "$RUN_DIR/store-degraded" ] || die "this boot is degraded — repair it first"
  [ ! -e "$STACK_DIR/next.json" ] || die "a new stack is pending in next.json — reboot first"
  [ -s "$STACK_DIR/current.json" ] || die "no current stack"
  keep=$(jq -r '.layers[].snapshot' "$STACK_DIR/current.json")
  [ "$(jq -r '.frozen | map(split("/")[-2]) | join(" ")' "$RUN_DIR/store-stack.json")" = "$(paste -sd' ' <<<"$keep")" ] ||
    die "this boot is not on current.json's stack — reboot on it first"
  # A listing that fails dies: a broken pool must not read as nothing to release.
  listed=$(zfs list -H -t snapshot -o name "$RW_DATASET" "$DB_DATASET") ||
    die "cannot list the stack's snapshots — nothing destroyed"
  if zfs list -H "$LAYERS_DATASET" >/dev/null 2>&1; then
    listed+=$'\n'$(zfs list -H -d 1 -t filesystem -o name "$LAYERS_DATASET") ||
      die "cannot list the layer datasets — nothing destroyed"
  fi
  # Only the stack's own names: the containers' delivery snapshots are theirs.
  obsolete=""
  while read -r ds; do
    [[ "$ds" =~ [@/]ndh-store-[0-9]{8}T[0-9]{6}Z$ ]] || continue
    grep -qxF "${ds##*[@/]}" <<<"$keep" || obsolete+="${obsolete:+$'\n'}$ds"
  done <<<"$listed"
  if [ -z "$obsolete" ]; then
    say "no layer to release"
    return
  fi
  # A container stacks the layers stamped at its delivery: none of them may go from under it.
  local stamped layer container
  for stamped in "$CONTAINER_STATE_ROOT"/*/lower.layers; do
    [ -e "$stamped" ] || continue
    container=$(basename "$(dirname "$stamped")")
    while read -r layer; do
      [[ "$layer" == "$FROZEN_ROOT"/*/upper ]] || continue
      layer="${layer#"$FROZEN_ROOT"/}"
      layer="${layer%/upper}"
      if grep -qE "[@/]$layer\$" <<<"$obsolete"; then
        die "container $container still stacks $layer — run: ndh-incus-container deliver $container, then confirm"
      fi
    done <"$stamped"
  done
  say "destroying the layers current.json no longer names:"
  listing "$obsolete"
  $yes || die "nothing destroyed — run again with --yes"
  while read -r ds; do
    zfs destroy -r "$ds"
  done <<<"$obsolete"
  if [ -e "$STACK_DIR/previous.json" ]; then rm "$STACK_DIR/previous.json"; fi
  say "released; the way back is now this stack only"
  say "trimming the pool's free space"
  zpool trim -w "${RW_DATASET%%/*}" || die "the trim failed — the freed blocks are still readable on the guest's disks"
  say "the host's disk image and its SSD may still hold the freed bytes: if a secret was frozen, ROTATE it"
}

case "${1:-}" in
  status) status ;;
  freeze)
    shift
    freeze "$@"
    ;;
  compact)
    shift
    compact "$@"
    ;;
  purge)
    shift
    purge "$@"
    ;;
  confirm) confirm "${2:-}" ;;
  *) usage ;;
esac
