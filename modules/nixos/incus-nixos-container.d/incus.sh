incus() { command incus "$@" </dev/null; }


incus:instance:name() {
  [[ $1 =~ ^[a-z][a-z0-9-]{0,62}$ ]] || util:die "'$1' is not an incus:instance name"
}

incus:instance() {
  incus:instance:name "$1"
  NAME="$1" yq -p json -o json -I0 -e '.[strenv(NAME)]' <<<"$INSTANCES" 2>/dev/null ||
    util:die "no incus:instance '$1' is declared on this member"
}

incus:locate() {
  incus info --project "$PROJECT" "$1" >/dev/null 2>&1 || { echo absent; return 0; }
  incus query "/1.0/instances/$1?project=$PROJECT" | yq -p json -oy -r '.location'
}

incus:placed:check() { [ -z "$2" ] || [ "$1" = "$2" ]; }


