zfs:snapshot:destroy() {
  local recursive=() target name attempt
  if [ "$1" = -r ]; then recursive=(-r); shift; fi
  name=${1#*@}
  for attempt in 1 2 3 4 5; do
    while read -r target; do
      [ -n "$target" ] || continue
      umount "$target" || true
    done < <(findmnt -rn -o TARGET | grep -E "/\.zfs/snapshot/${name//./\\.}(/|\$)" || true)
    if zfs destroy "${recursive[@]}" "$1"; then return 0; fi
    [ "$attempt" = 5 ] || sleep 2
  done
  echo "ndh-incus-container: $1 is still busy after 5 attempts" >&2
  return 1
}

zfs:snapshot:list() {
  local state
  for state in $(yq -p json -oy -r '(.stateDatasets // []) | .[]' <<<"$1"); do
    zfs list -H -t snapshot -o name "${state:?}" | grep -E "@ndh-incus-$2-[0-9]{8}T[0-9]{6}Z\$" || true
  done
}

