#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
  manage="${MANAGE_AUTO_MASTER:-1}"
  auto_master="/etc/auto_master"

  resolve_master_path() {
    path="$1"
    if [ -L "$path" ]; then
      target="$(readlink "$path")"
      case "$target" in
        /*) path="$target" ;;
        *) path="$(dirname "$path")/$target" ;;
      esac
    fi
    printf '%s\n' "$path"
  }

  ensure_entry() {
    mp="$1"; map="$2"; opts="$3"
    tmp="$(mktemp)"
    if [ -f "$auto_master" ]; then
      awk -v mp="$mp" -v map="$map" -v opts="$opts" '
        BEGIN { updated = 0 }
        $1 == mp { print mp "\t" map "\t" opts; updated = 1; next }
        { print }
        END {
          if (updated == 0) {
            print mp "\t" map "\t" opts
          }
        }
      ' "$auto_master" > "$tmp"
    else
      printf "%s\t%s\t%s\n" "$mp" "$map" "$opts" > "$tmp"
    fi
    install -m 0644 "$tmp" "$auto_master"
    rm -f "$tmp"
  }

  auto_master="$(resolve_master_path "$auto_master")"

  if [ "$manage" = "0" ]; then
    ensure_entry "${MOUNT_POINT}" "${MAP}" "${OPTIONS}"
  fi

  /usr/sbin/automount -cv >/dev/null
}

activation_run darwin.activationScripts.etc.nfs-autofs-refresh main "$@"
