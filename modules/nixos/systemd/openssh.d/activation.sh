#!/usr/bin/env bash
source @activationLogger@

main() {
  set -euo pipefail

  SSH_AUTH_KEYS_DIR=/etc/ssh/authorized_keys.d
  SSH_KEYS_DIR=@keysDir@
  HOSTNAME=@hostname@
  PRINCIPALS_CMD=@principalsCommand@
  GROUP_CMD=@groupCommand@
  PRINCIPALS_SRC=@principalsScript@
  GROUP_SRC=@groupKeysScript@

  install -d -m 755 "$SSH_AUTH_KEYS_DIR"
  install -d -m 755 "$SSH_KEYS_DIR"

  SSH_KEY_NIXBLD="$SSH_KEYS_DIR/nixbld"
  if [ ! -f "$SSH_KEY_NIXBLD" ]; then
    @sshKeygen@ -t ed25519 -f "$SSH_KEY_NIXBLD" -N "" -C "nixbld@$HOSTNAME"
    chmod a+r "${SSH_KEY_NIXBLD}.pub"
    ln -sf "${SSH_KEY_NIXBLD}.pub" "$SSH_AUTH_KEYS_DIR/nixbld"
  fi

  if [ -f "$SSH_KEYS_DIR/mammoth_skate-ca.pub" ]; then
    chmod 644 "$SSH_KEYS_DIR/mammoth_skate-ca.pub"
  fi

  install -m 555 "$GROUP_SRC" /etc/ssh/$GROUP_CMD
  if [ ! -e /etc/ssh/ssh-group-authorized-keys ]; then
    ln -s "$GROUP_CMD" /etc/ssh/ssh-group-authorized-keys
  fi
  install -m 555 "$PRINCIPALS_SRC" /etc/ssh/$PRINCIPALS_CMD
  if [ ! -e /etc/ssh/authorized-principals-command ]; then
    ln -s "$PRINCIPALS_CMD" /etc/ssh/authorized-principals-command
  fi

  install -d -m 755 /etc/ssh/sshd_config.d
  install -d -m 755 /etc/ssh/ssh_config.d
}

activation_run "@activationTag@" main "$@"
