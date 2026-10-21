# flox-config — set and remove top-level keys of flox's user config one by one, never replacing the file.
#
#   flox-config <flox.toml> [--set <key> <toml value>]... [--delete <key>]...
#
# ~/.config/flox/flox.toml also holds what the operator keeps by hand (auto_activate_environments), so it is not a
# home-manager file: only the named keys change, every other line stays byte for byte. The file is rewritten only
# when that changes something, in one rename, keeping its mode. A missing file is created holding the set keys only.
#
# Lines are edited here, never by a TOML writer: yq-go appends a new top-level key after the last table, inside it,
# and dasel's round trip drops every comment (measured 2026-10-21). dasel only reads the result to check it.

file="${1:?usage: flox-config <flox.toml> [--set <key> <value>]... [--delete <key>]...}"
shift
sets=()
deletes=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --set) sets+=("$2=$3"); shift 3 ;;
    --delete) deletes+=("$2"); shift 2 ;;
    *) echo "flox-config: unknown argument $1" >&2; exit 2 ;;
  esac
done
for kv in "${sets[@]}" "${deletes[@]}"; do
  [[ ${kv%%=*} =~ ^[A-Za-z0-9_-]+$ ]] || { echo "flox-config: ${kv%%=*} is not a bare TOML key" >&2; exit 2; }
done

mkdir -p "$(dirname "$file")"
new=$(mktemp "$file.XXXXXX")
trap 'rm -f "$new"' EXIT
[ -e "$file" ] && cp -p "$file" "$new"

# The awk programs, single-quoted on purpose: their $0 is awk's, not the shell's. A top-level line of a key is one
# before the first table header, `key =` with optional spaces.
# shellcheck disable=SC2016
{
  is_top='BEGIN { re = "^[ \t]*" k "[ \t]*=" } /^[ \t]*\[/ { exit } $0 ~ re { found = 1 } END { exit !found }'
  drop_top='BEGIN { re = "^[ \t]*" k "[ \t]*=" } /^[ \t]*\[/ { top = 1 } !top && $0 ~ re { next } { print }'
  replace_top='BEGIN { re = "^[ \t]*" k "[ \t]*=" } /^[ \t]*\[/ { top = 1 } !top && $0 ~ re { print line; next } { print }'
  insert_top='!done && /^[ \t]*\[/ { print line; print ""; done = 1 } { print } END { if (!done) print line }'
}
toplevel_key() { awk -v k="$1" "$is_top" "$new"; }
edit() { # <awk program> <key> [<line>]
  awk -v k="$2" -v line="${3:-}" "$1" "$new" >"$new.t" && cat "$new.t" >"$new" && rm -f "$new.t"
}
for k in "${deletes[@]}"; do
  edit "$drop_top" "$k"
done
for kv in "${sets[@]}"; do
  k=${kv%%=*} v=${kv#*=}
  if toplevel_key "$k"; then
    edit "$replace_top" "$k" "$k = $v"
  else
    # Before the first table, or at the end of a file that has none.
    edit "$insert_top" "$k" "$k = $v"
  fi
done

# The result must still be TOML, and say what was asked; otherwise the file stays as it was. yq validates: dasel 3.8.1
# stops at the first invalid line and returns what it read so far, rc 0 (measured 2026-10-21). dasel (the codebase's
# TOML reader) then reads the values; written back, it would drop every comment.
yq -p toml -o json -I0 '.' "$new" >/dev/null || { echo "flox-config: the result would not be TOML; $file left as it was" >&2; exit 1; }
as_json() { dasel -i toml -o json <"$1" | yq -p json -o json -I0 '.'; }
read=$(as_json "$new") || { echo "flox-config: $file cannot be read; left as it was" >&2; exit 1; }
probe=$(mktemp "$file.XXXXXX")
trap 'rm -f "$new" "$probe"' EXIT
for kv in "${sets[@]}"; do
  k=${kv%%=*}
  printf 'x = %s\n' "${kv#*=}" >"$probe"
  [ "$(yq -p json -o json -I0 ".\"$k\"" <<<"$read")" = "$(as_json "$probe" | yq -p json -o json -I0 '.x')" ] ||
    { echo "flox-config: $k did not take its value; $file left as it was" >&2; exit 1; }
done
for k in "${deletes[@]}"; do
  [ "$(yq -p json -o json -I0 "has(\"$k\")" <<<"$read")" = false ] || { echo "flox-config: $k is still there; $file left as it was" >&2; exit 1; }
done

if [ -e "$file" ] && cmp -s "$file" "$new"; then exit 0; fi
[ -e "$file" ] || chmod 0644 "$new"
mv -f "$new" "$file"
echo "[flox-config] $file: ${sets[*]} ${deletes[*]/#/-}"
