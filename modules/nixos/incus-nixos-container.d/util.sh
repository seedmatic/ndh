util:usage() {
  sed -n '/^#   ndh-incus-container /p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

util:die() {
  echo "ndh-incus-container: $1" >&2
  exit 1
}

util:field() { KEY="$2" yq -p json -oy -r '.[strenv(KEY)]' <<<"$1"; }


util:raw_lxc:build() {
  printf 'lxc.init.cmd = /nix/var/nix/profiles/system/init\nlxc.hook.pre-start = %s %s\n' "$PRESTART_HOOK" "$1"
}

util:root:verify() {
  local p="$1" c rel
  IFS=/ read -ra rel <<<"$2"
  for c in "" "${rel[@]}"; do
    p="$p${c:+/$c}"
    if [ -e "$p" ] || [ -L "$p" ]; then
      [ -d "$p" ] && [ ! -L "$p" ] && [ "$(stat -c %u "$p")" = 0 ] ||
        util:die "$p is not root's own directory — nothing delivered, and the container stays STOPPED"
    fi
  done
}

