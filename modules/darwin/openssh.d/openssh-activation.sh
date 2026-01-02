#!/usr/bin/env -S bash -xeuo pipefail
LOG="/var/log/darwin-openssh-activation.log"
install -d -m 755 /var/log
{
  echo "[openssh] start $(date)"

  : "Install builder keys for nix daemon (root) access (Darwin)"
  install -d -m 755 /etc/ssh
  install -d -m 700 @nixKeyDir@

  install -m 600 -o root -g wheel @builderPrivStore@ @nixKey@
  install -m 644 -o root -g wheel @builderPubStore@ @nixKeyPub@

  : "Install group-based AuthorizedKeysCommand script"
  install -d -m 755 /etc/ssh
  install -m 555 @groupKeysScriptStore@ /etc/ssh/@groupKeysCommand@
  install -m 555 @principalsScriptStore@ /etc/ssh/@principalsCommand@

  echo "[openssh] end $(date)"
} >>"$LOG" 2>&1
