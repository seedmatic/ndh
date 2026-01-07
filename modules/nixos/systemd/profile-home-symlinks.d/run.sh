#!/usr/bin/env bash
set -euo pipefail

current_home=@currentHome@
current_user=@cfgUserName@
current_home_base=@currentHomeBase@
create_script=@createScript@
home_aliases="@homeAliases@"

log() { echo "[profile-home-symlinks] $*"; }

log "current user: ${current_user} home: ${current_home}"

# Linux-style /home aliases
set -- ${home_aliases}
for alias in "$@"; do
  [ -z "$alias" ] && continue
  "${create_script}" "${current_home}" "${current_home_base}/${alias}"
done

# macOS-style /Users layout
if [ -d /Users ]; then
  "${create_script}" "${current_home}" "/Users/${current_user}"
  set -- ${home_aliases}
  for alias in "$@"; do
    [ -z "$alias" ] && continue
    "${create_script}" "${current_home}" "/Users/${alias}"
  done
fi
