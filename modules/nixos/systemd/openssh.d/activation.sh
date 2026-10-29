#!/usr/bin/env bash
# shellcheck disable=SC1091
source "@nixBashTrampoline@"

main() {
  set -euo pipefail

  SSH_AUTH_KEYS_DIR=@authorizedKeysDir@
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
    ssh-keygen -t ed25519 -f "$SSH_KEY_NIXBLD" -N "" -C "nixbld@$HOSTNAME"
    chmod a+r "${SSH_KEY_NIXBLD}.pub"
    ln -sf "${SSH_KEY_NIXBLD}.pub" "$SSH_AUTH_KEYS_DIR/nixbld"
  fi

  # CA public keys + trusted-user-ca.pub aggregate are materialized directly
  # inside SSH_KEYS_DIR by the ssh-keys enrichment systemd unit
  # (modules/nixos/systemd/ssh-keys-enrichment.nix). No /etc/ssh/keys.d mirror
  # needed — sshd's TrustedUserCAKeys points at SSH_KEYS_DIR/trusted-user-ca.pub.

  # The operator logs in by their ssh-user certificate (TrustedUserCAKeys) or the authorized_keys line
  # NixOS renders from keys.yaml (/etc/ssh/authorized_keys.d); root holds no client identity of its own.

  install -m 555 "$GROUP_SRC" /etc/ssh/$GROUP_CMD
  ln -sfn "$GROUP_CMD" /etc/ssh/ssh-group-authorized-keys
  install -m 555 "$PRINCIPALS_SRC" /etc/ssh/$PRINCIPALS_CMD
  ln -sfn "$PRINCIPALS_CMD" /etc/ssh/authorized-principals-command

  install -d -m 755 /etc/ssh/sshd_config.d
  install -d -m 755 /etc/ssh/ssh_config.d
}

ndh::logger:command:run "@loggerTag@" main "$@"
