#!/usr/bin/env -S bash -euo pipefail

LOG="/var/log/static-routes.log"
touch "$LOG" || true

ensure_route() {
  local kind="$1"
  local destination="$2"
  local gateway="$3"
  local ifscope="$4"
  local scope_note=""

  if [[ -n "$ifscope" ]]; then
    scope_note=" ifscope $ifscope"
  fi

  local current_gateway current_interface
  current_gateway="$(/sbin/route -n get "$destination" 2>/dev/null | awk '/gateway:/{print $2; exit}')"
  current_interface="$(/sbin/route -n get "$destination" 2>/dev/null | awk '/interface:/{print $2; exit}')"

  if [[ "$current_gateway" == "$gateway" ]]; then
    if [[ -z "$ifscope" || "$current_interface" == "$ifscope" ]]; then
      echo "[static-routes] OK $kind $destination via $gateway$scope_note" >> "$LOG"
      return 0
    fi
  fi

  /sbin/route -n delete -"$kind" "$destination" >/dev/null 2>&1 || true

  if [[ -n "$ifscope" ]]; then
    /sbin/route -n add -"$kind" "$destination" "$gateway" -ifscope "$ifscope" >/dev/null 2>&1 \
      || /sbin/route -n change -"$kind" "$destination" "$gateway" -ifscope "$ifscope" >/dev/null 2>&1 \
      || true
  else
    /sbin/route -n add -"$kind" "$destination" "$gateway" >/dev/null 2>&1 \
      || /sbin/route -n change -"$kind" "$destination" "$gateway" >/dev/null 2>&1 \
      || true
  fi

  current_gateway="$(/sbin/route -n get "$destination" 2>/dev/null | awk '/gateway:/{print $2; exit}')"
  current_interface="$(/sbin/route -n get "$destination" 2>/dev/null | awk '/interface:/{print $2; exit}')"

  if [[ "$current_gateway" == "$gateway" ]] && [[ -z "$ifscope" || "$current_interface" == "$ifscope" ]]; then
    echo "[static-routes] SET $kind $destination via $gateway$scope_note" >> "$LOG"
  else
    echo "[static-routes] WARN failed to enforce $kind $destination via $gateway$scope_note" >> "$LOG"
  fi
}

@ensureRoutesCommands@
