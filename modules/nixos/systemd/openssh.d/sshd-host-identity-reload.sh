#!/usr/bin/env bash
# @codebase
set -euo pipefail

# shellcheck disable=SC1091
source @nixBashTrampoline@

LOG_TAG=@logTag@

# The host key sshd serves and the certificate it presents come out of the SAME
# home-manager extraction, so they are installed here, together, right after it.
#
# The key used to be copied by a system activation script, which runs BEFORE that
# extraction: it installed the key extracted the time before. Outside a renewal
# the two are equal and nothing shows. During an rdp-host renewal the served key
# would be the retiring generation while the certificate certifies the new one —
# sshd ignores a certificate that matches none of its keys, and every client then
# fails host verification until a second activation.
#
# Then sshd is restarted, because it reads both only at start. A restart, not a
# reload: NixOS's sshd unit has no ExecReload. KillMode=process leaves open
# sessions alone. --no-block because this runs inside the home-manager unit's
# start job, possibly in the same transaction as sshd's.
install_host_key() {
  if [[ ! -s "@hostKeySource@" ]]; then
    logger -p auth.warning -t "$LOG_TAG" "no extracted host key at @hostKeySource@; @systemHostKey@ left as is"
    return 0
  fi
  if cmp -s "@hostKeySource@" "@systemHostKey@"; then
    return 0
  fi

  install -m 600 "@hostKeySource@" "@systemHostKey@"
  if [[ -s "@hostKeyPublicSource@" ]]; then
    install -m 644 "@hostKeyPublicSource@" "@systemHostKey@.pub"
  else
    ssh-keygen -y -f "@systemHostKey@" >"@systemHostKey@.pub"
    chmod 644 "@systemHostKey@.pub"
  fi
  logger -p auth.notice -t "$LOG_TAG" "installed @hostKeySource@ as @systemHostKey@"
}

main() {
  unit="sshd.service"

  install_host_key

  if ! systemctl is-active --quiet "$unit"; then
    logger -p auth.info -t "$LOG_TAG" "sshd not active; it will load the host key and @hostCertificatePath@ when it starts"
    return 0
  fi

  if [[ ! -e "@hostCertificatePath@" ]]; then
    logger -p auth.warning -t "$LOG_TAG" "no host certificate at @hostCertificatePath@; sshd restarted for the key alone"
  fi

  systemctl try-restart --no-block "$unit"
  logger -p auth.info -t "$LOG_TAG" "sshd restart queued to load @systemHostKey@ and @hostCertificatePath@"
}

ndh::logger:command:run "@logTag@" main "$@"
