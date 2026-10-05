#!/usr/bin/env bash
# @codebase
set -euo pipefail

# shellcheck disable=SC1091
source @nixBashTrampoline@

LOG_TAG=@logTag@

# sshd reads HostCertificate once, at start, and the certificate is written later
# by the home-manager extraction — on every activation, because the enrichment
# re-signs each run. Measured: sshd started 4s before the rewrite and went on
# presenting the previous certificate until restarted by hand.
#
# A restart, not a reload: NixOS's sshd unit has no ExecReload. KillMode=process
# leaves open sessions alone. --no-block because this runs inside the
# home-manager unit's start job, possibly in the same transaction as sshd's.
main() {
  unit="sshd.service"

  if ! systemctl is-active --quiet "$unit"; then
    logger -p auth.info -t "$LOG_TAG" "sshd not active; it will load @hostCertificatePath@ when it starts"
    return 0
  fi

  if [[ ! -e "@hostCertificatePath@" ]]; then
    logger -p auth.warning -t "$LOG_TAG" "no host certificate at @hostCertificatePath@; sshd left as is"
    return 0
  fi

  systemctl try-restart --no-block "$unit"
  logger -p auth.info -t "$LOG_TAG" "sshd restart queued to load @hostCertificatePath@"
}

ndh::logger:command:run "@logTag@" main "$@"
