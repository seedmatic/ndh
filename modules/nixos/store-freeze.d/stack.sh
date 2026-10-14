# Stage 1: build nerd-nixos's /nix/store from its stack manifest (docs/store-freeze-spec.adoc).
#
# The store is mounted FLAT: the frozen layers, newest first, then the EROFS layers, under the
# upper. A whiteout in a frozen layer must mask the EROFS paths below it, and an overlay used as a
# lowerdir would consume its whiteouts instead of passing them on.
#
# Manifests live in $STACK_DIR on the upper's dataset: next.json (written by `ndh-store freeze`),
# current.json, previous.json. The first valid one, in that order, is the stack. `upper.base` names
# the layers the upper sits on: a stack is consistent only if it equals it, or extends it by the one
# layer frozen from it — then the upper is emptied, once, before mounting.
#
# Never fails the boot for a manifest problem: it falls back to an older stack, else to the bare
# EROFS layers, mounted read-only WITHOUT the upper, and writes $RUN_DIR/store-degraded, which masks
# nix-daemon in stage 2 and fails a unit loudly. It fails only when no store can be mounted at all.
#
# Env: SYSROOT, RW_DATASET, RW_MOUNT, STACK_DIR, FROZEN_ROOT, EROFS_LOWERS (colon list, newest first),
#      RUN_DIR, MANIFEST_VERSION.

stack="$SYSROOT$STACK_DIR"
rw="$SYSROOT$RW_MOUNT"
store="$SYSROOT/nix/store"
mkdir -p "$RUN_DIR" "$stack"

say() { echo "ndh-store-stack: $*" >&2; }

degraded=""
degrade() {
  say "DEGRADED — $1"
  degraded="${degraded:+$degraded; }$1"
}

# write {path} {content}: temporary file, rename, then fsync of the directory.
write() {
  printf '%s\n' "$2" >"$1.tmp"
  sync "$1.tmp"
  mv "$1.tmp" "$1"
  sync "$(dirname "$1")"
}

# layers_of {manifest} — prints "snapshot guid" per layer, newest first; returns 1 and prints the
# reason on stderr when the manifest is unusable.
layers_of() {
  local f="$1" version ds snap guid actual
  if [ ! -s "$f" ]; then
    echo "missing or empty" >&2
    return 1
  fi
  if ! version=$(jq -er '.version' "$f" 2>/dev/null); then
    echo "unreadable" >&2
    return 1
  fi
  if [ "$version" != "$MANIFEST_VERSION" ]; then
    echo "version $version, this initrd knows $MANIFEST_VERSION" >&2
    return 1
  fi
  if ! jq -er '.layers | type == "array"' "$f" >/dev/null 2>&1; then
    echo "no layer list" >&2
    return 1
  fi
  while IFS=$'\t' read -r ds snap guid; do
    if [ "$ds" != "$RW_DATASET" ]; then
      echo "layer $snap belongs to $ds, not $RW_DATASET" >&2
      return 1
    fi
    if ! [[ "$snap" =~ ^ndh-store-[0-9]{8}T[0-9]{6}Z$ ]]; then
      echo "layer name $snap" >&2
      return 1
    fi
    if ! actual=$(zfs get -H -o value guid "$ds@$snap" 2>/dev/null); then
      echo "snapshot $ds@$snap is missing" >&2
      return 1
    fi
    if [ "$actual" != "$guid" ]; then
      echo "snapshot $snap has GUID $actual, the manifest names $guid" >&2
      return 1
    fi
    echo "$snap $guid"
  done < <(jq -r '.layers[] | [.dataset, .snapshot, .guid] | @tsv' "$f")
}

base=""
if [ -s "$rw/upper.base" ]; then base=$(cat "$rw/upper.base"); fi

chosen="none"
layers=""
for candidate in next current previous; do
  if reason=$(layers_of "$stack/$candidate.json" 2>&1 >/dev/null); then
    layers=$(layers_of "$stack/$candidate.json")
    chosen="$candidate"
    break
  fi
  if [ -e "$stack/$candidate.json" ]; then degrade "$candidate.json refused: $reason"; fi
done

names=$(awk '{print $1}' <<<"$layers" | paste -sd' ')
# The stack must be the upper's base, or extend it by exactly the one layer frozen from it.
if [ "$names" != "$base" ]; then
  tail=$(cut -s -d' ' -f2- <<<"$names")
  if [ "$chosen" = "next" ] && [ "$tail" = "$base" ] && [ -n "$names" ]; then
    trash="$rw/trash/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$trash"
    if [ -d "$rw/upper" ]; then mv "$rw/upper" "$trash/"; fi
    if [ -d "$rw/work" ]; then mv "$rw/work" "$trash/"; fi
    mkdir -p "$rw/upper" "$rw/work"
    write "$rw/upper.base" "$names"
    say "new stack applied: the upper starts empty on ${names%% *}"
  else
    degrade "the stack ($chosen: ${names:-bare EROFS}) is not the one the upper sits on (${base:-bare EROFS})"
  fi
fi

lowerdirs=""
stage2=""
for snap in $names; do
  dir="$SYSROOT$FROZEN_ROOT/$snap"
  mkdir -p "$dir"
  if ! mountpoint -q "$dir"; then
    if ! mount -t zfs -o ro "$RW_DATASET@$snap" "$dir"; then
      degrade "cannot mount $RW_DATASET@$snap"
      lowerdirs=""
      stage2=""
      break
    fi
  fi
  lowerdirs="${lowerdirs:+$lowerdirs:}$dir/upper"
  stage2="${stage2:+$stage2,}\"$FROZEN_ROOT/$snap/upper\""
done

erofs_sysroot=$(tr ':' '\n' <<<"$EROFS_LOWERS" | sed "s|^|$SYSROOT|" | paste -sd:)
mkdir -p "$store"

# Degraded: the lowers only, NO upper — a read-only overlay. The persistent upper was built on
# another base, so it is never mixed with this stack nor written while degraded, and the store is
# read-only by construction rather than by a remount that could fail (🛡️ review of af723ca3).
mount_degraded() {
  mount -t overlay overlay -o "ro,lowerdir=${1:+$1:}$erofs_sysroot" "$store"
}

if [ -n "$degraded" ]; then
  if ! mount_degraded "$lowerdirs"; then
    stage2=""
    mount_degraded ""
  fi
else
  mkdir -p "$rw/upper" "$rw/work"
  if ! mount -t overlay overlay \
    -o "lowerdir=${lowerdirs:+$lowerdirs:}$erofs_sysroot,upperdir=$rw/upper,workdir=$rw/work" "$store"; then
    degrade "the stack did not mount; the bare EROFS layers, read-only"
    stage2=""
    mount_degraded ""
  fi
fi

erofs_json=$(tr ':' '\n' <<<"$EROFS_LOWERS" | sed 's/.*/"&"/' | paste -sd,)
write "$RUN_DIR/store-stack.json" \
  "{\"manifest\":\"$chosen\",\"frozen\":[${stage2}],\"erofs\":[${erofs_json}]}"

# A freeze the gesture asked for and this boot does not show is REPORTED, never performed.
if [ -s "$stack/request.json" ]; then
  wanted=$(jq -r '.snapshot // empty' "$stack/request.json" 2>/dev/null || true)
  if [ -n "$wanted" ] && [[ " $names " != *" $wanted "* ]]; then
    say "a freeze was requested ($wanted) and is not in this stack"
    printf '%s\n' "$wanted" >"$RUN_DIR/store-freeze-not-done"
  fi
fi

if [ -n "$degraded" ]; then printf '%s\n' "$degraded" >"$RUN_DIR/store-degraded"; fi
say "manifest $chosen, ${names:-no frozen layer}${degraded:+ — DEGRADED}"
