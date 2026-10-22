# Stage 2, once multi-user is reached: the stack this boot was built on becomes the current one
# (docs/store-freeze-spec.adoc, the A/B manifest). Until then the previous manifest stays the way
# back. A degraded boot commits nothing.
#
# Env: STACK_DIR, RW_MOUNT, RUN_DIR.

if [ ! -s "$RUN_DIR/store-stack.json" ]; then
  echo "ndh-store-commit: no stack description from the initrd, nothing to commit" >&2
  exit 0
fi
if [ -e "$RUN_DIR/store-degraded" ]; then
  echo "ndh-store-commit: degraded boot, nothing committed" >&2
  exit 0
fi

sync_rename() {
  mv "$1" "$2"
  sync "$(dirname "$2")"
}

chosen=$(yq -p json -o json -r '.manifest' "$RUN_DIR/store-stack.json")
if [ "$chosen" = "next" ]; then
  if [ -e "$STACK_DIR/current.json" ]; then sync_rename "$STACK_DIR/current.json" "$STACK_DIR/previous.json"; fi
  sync_rename "$STACK_DIR/next.json" "$STACK_DIR/current.json"
  echo "ndh-store-commit: the new stack is now the current one" >&2
elif [ -e "$STACK_DIR/next.json" ]; then
  # Refused by the initrd: kept as evidence, out of the way of the next freeze.
  mkdir -p "$STACK_DIR/refused"
  sync_rename "$STACK_DIR/next.json" "$STACK_DIR/refused/next-$(date -u +%Y%m%dT%H%M%SZ).json"
  echo "ndh-store-commit: the refused next manifest is set aside in $STACK_DIR/refused" >&2
fi

# A freeze request this stack satisfies is done.
if [ -s "$STACK_DIR/request.json" ] && [ -s "$STACK_DIR/current.json" ]; then
  # yq-go has no `empty`: `// empty` is a syntax error there, on every input. `// ""` gives jq's `// empty` exactly,
  # nothing and exit 0 on a null, a missing or an empty snapshot (measured). A request without one is not satisfied.
  wanted=$(yq -p json -o json -r '.snapshot // ""' "$STACK_DIR/request.json")
  if [ -n "$wanted" ] && S="$wanted" yq -p json -o json -e '[.layers[].snapshot] | any_c(. == strenv(S))' "$STACK_DIR/current.json" >/dev/null; then
    rm "$STACK_DIR/request.json"
  fi
fi

# The uppers set aside when a new stack was applied: their blocks are held by the snapshot anyway.
for old in "$RW_MOUNT"/trash/*; do
  if [ -d "$old" ]; then rm -rf --one-file-system "$old"; fi
done
