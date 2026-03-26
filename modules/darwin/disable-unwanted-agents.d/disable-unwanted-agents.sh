#!/usr/bin/env -S bash -euo pipefail

log() {
  /bin/echo "[disable-unwanted-agents] $*"
}

console_uid() {
  /usr/bin/stat -f %u /dev/console 2>/dev/null || true
}

plist_label() {
  local plist="$1"
  /usr/libexec/PlistBuddy -c "Print :Label" "$plist" 2>/dev/null ||
    /usr/bin/basename "$plist" .plist
}

disable_label_in_domain() {
  local domain="$1"
  local label="$2"

  [ -n "$domain" ] || return 0
  [ -n "$label" ] || return 0

  /bin/launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  /bin/launchctl disable "$domain/$label" >/dev/null 2>&1 || true
}

disable_plist() {
  local plist="$1"
  local label domain uid

  [ -f "$plist" ] || return 0

  label=$(plist_label "$plist")
  if [ -z "$label" ]; then
    log "Skipping unlabeled plist: $plist"
    return 0
  fi

  case "$plist" in
    /Library/LaunchDaemons/*)
      domain="system"
      ;;
    /Library/LaunchAgents/*)
      uid=$(console_uid)
      if [ -n "$uid" ]; then
        domain="gui/$uid"
      else
        domain=""
      fi
      ;;
    "$HOME"/Library/LaunchAgents/*)
      uid=$(/usr/bin/id -u)
      domain="gui/$uid"
      ;;
    *)
      domain=""
      ;;
  esac

  if [ -n "$domain" ]; then
    disable_label_in_domain "$domain" "$label"
  fi

  /bin/launchctl unload -w "$plist" >/dev/null 2>&1 || true
  log "Disabled $label from $(/usr/bin/basename "$plist")"
}

disable_known_safe_labels() {
  local uid
  uid=$(console_uid)

  # Microsoft AutoUpdate helpers
  disable_label_in_domain "system" "com.microsoft.autoupdate.helper"
  if [ -n "$uid" ]; then
    disable_label_in_domain "gui/$uid" "com.microsoft.update.agent"
  fi
}

main() {
  local found=0
  local pattern plist

  disable_known_safe_labels

  for pattern in \
    "$HOME/Library/LaunchAgents/com.duet*.plist" \
    "/Library/LaunchAgents/com.duet*.plist" \
    "/Library/LaunchDaemons/com.duet*.plist" \
    "/Library/LaunchAgents/*Duet*.plist" \
    "/Library/LaunchDaemons/*Duet*.plist" \
    "/Library/LaunchAgents/com.microsoft.update.agent.plist" \
    "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist"; do
    for plist in $pattern; do
      [ -e "$plist" ] || continue
      found=1
      disable_plist "$plist"
    done
  done

  if [ "$found" -eq 0 ]; then
    log "No optional unwanted agents found"
  fi
}

main "$@"