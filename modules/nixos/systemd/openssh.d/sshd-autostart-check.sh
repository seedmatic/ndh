#!/usr/bin/env bash
# @codebase
set -euo pipefail

# shellcheck disable=SC1091
source @bashTrampoline@
# shellcheck disable=SC1091
source @logger@

LOG_TAG=@logTag@

main() {
  unit="sshd.service"

  unit_file_state="$(systemctl show "$unit" -p UnitFileState --value 2>/dev/null || true)"
  active_state="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)"
  sub_state="$(systemctl show "$unit" -p SubState --value 2>/dev/null || true)"

  if [[ "$unit_file_state" != "enabled" ]]; then
    logger -p auth.err -t "$LOG_TAG" "unexpected sshd unit file state: ${unit_file_state:-<empty>}"
    exit 1
  fi

  if [[ "$active_state" != "active" ]]; then
    logger -p auth.err -t "$LOG_TAG" "sshd not active after contributed target: ActiveState=${active_state:-<empty>} SubState=${sub_state:-<empty>}"
    exit 1
  fi

  logger -p auth.info -t "$LOG_TAG" "sshd autostart check passed: UnitFileState=${unit_file_state} ActiveState=${active_state} SubState=${sub_state}"
}

ndh::logger:command:run "@logTag@" main "$@"
