#!/usr/bin/env -S bash -xeuo pipefail
LOG="/var/log/darwin-openssh-activation.log"
install -d -m 755 /var/log
{
  echo "[openssh] start $(date)"

  : "Install group-based AuthorizedKeysCommand script"
  install -d -m 755 /etc/ssh
  install -m 555 @groupKeysScriptStore@ /etc/ssh/@groupKeysCommand@
  install -m 555 @principalsScriptStore@ /etc/ssh/@principalsCommand@

  echo "[openssh] end $(date)"
} >>"$LOG" 2>&1
