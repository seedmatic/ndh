#!/usr/bin/env bash
# shellcheck disable=SC1091
source "@nixBashTrampoline@"

main() {
  set -euo pipefail

  SSH_AUTH_KEYS_DIR=@authorizedKeysDir@
  SSH_KEYS_DIR=@keysDir@
  USER_PRIVATE_SOURCE_DIR=@userPrivateSourceDir@
  USER_CA_SOURCE_DIR=@userCaSourceDir@
  PROFILE_USER_NAME=@profileUserName@
  ROOT_SSH_DIR=/root/.ssh
  SYSTEM_HOST_KEY=/etc/ssh/ssh_host_ed25519_key
  SYSTEM_HOST_KEY_PUB=/etc/ssh/ssh_host_ed25519_key.pub
  HOSTNAME=@hostname@
  PRINCIPALS_CMD=@principalsCommand@
  GROUP_CMD=@groupCommand@
  PRINCIPALS_SRC=@principalsScript@
  GROUP_SRC=@groupKeysScript@
  CLIENT_KEY_NAME=@clientKeyName@
  SERVER_KEY_NAME="$CLIENT_KEY_NAME"

  SERVER_PRIVATE_SOURCE="$USER_PRIVATE_SOURCE_DIR/$SERVER_KEY_NAME"
  SERVER_PUBLIC_SOURCE="$USER_CA_SOURCE_DIR/$SERVER_KEY_NAME.pub"
  CLIENT_PRIVATE_SOURCE="$USER_PRIVATE_SOURCE_DIR/$CLIENT_KEY_NAME"
  CLIENT_PUBLIC_SOURCE="$USER_CA_SOURCE_DIR/$CLIENT_KEY_NAME.pub"

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

  # Canonical host SSH identity: install persisted SOPS-managed key material
  # so renewed VM instances keep a stable host key and known_hosts remains valid.
  if [ -s "$SERVER_PRIVATE_SOURCE" ]; then
    install -m 600 "$SERVER_PRIVATE_SOURCE" "$SYSTEM_HOST_KEY"
    if [ -s "$SERVER_PUBLIC_SOURCE" ]; then
      install -m 644 "$SERVER_PUBLIC_SOURCE" "$SYSTEM_HOST_KEY_PUB"
    else
      ssh-keygen -y -f "$SYSTEM_HOST_KEY" > "$SYSTEM_HOST_KEY_PUB"
      chmod 644 "$SYSTEM_HOST_KEY_PUB"
    fi
  fi

  # Keep a root-local client identity available for early boot/activation SSH calls.
  # Home-manager key extraction is user-scoped, so duplicate the RDP host client key for root here.
  if [ -s "$CLIENT_PRIVATE_SOURCE" ]; then
    install -d -m 700 "$ROOT_SSH_DIR"
    install -m 600 "$CLIENT_PRIVATE_SOURCE" "$ROOT_SSH_DIR/id_ed25519"
    if [ -s "$CLIENT_PUBLIC_SOURCE" ]; then
      install -m 644 "$CLIENT_PUBLIC_SOURCE" "$ROOT_SSH_DIR/id_ed25519.pub"
    fi
  elif [ -s "$SYSTEM_HOST_KEY" ]; then
    # Bootstrap fallback: use system host key as root client identity until
    # runtime per-user key material is available.
    install -d -m 700 "$ROOT_SSH_DIR"
    install -m 600 "$SYSTEM_HOST_KEY" "$ROOT_SSH_DIR/id_ed25519"
    if [ -s "$SYSTEM_HOST_KEY_PUB" ]; then
      install -m 644 "$SYSTEM_HOST_KEY_PUB" "$ROOT_SSH_DIR/id_ed25519.pub"
    fi
  fi

  # Ensure profile user can authenticate with the host identity key.
  if [ -n "$PROFILE_USER_NAME" ] && [ -s "$CLIENT_PUBLIC_SOURCE" ]; then
    install -d -m 755 "$SSH_AUTH_KEYS_DIR"
    install -m 644 "$CLIENT_PUBLIC_SOURCE" "$SSH_AUTH_KEYS_DIR/$PROFILE_USER_NAME"
  fi

  # Ensure root can authenticate during first-bootstrap remote operations.
  # Primary source: runtime host public key; fallback to profile user's key file
  # if runtime key material is not populated yet.
  if [ -s "$CLIENT_PUBLIC_SOURCE" ]; then
    install -d -m 755 "$SSH_AUTH_KEYS_DIR"
    install -m 644 "$CLIENT_PUBLIC_SOURCE" "$SSH_AUTH_KEYS_DIR/root"
  elif [ -n "$PROFILE_USER_NAME" ] && [ -s "$SSH_AUTH_KEYS_DIR/$PROFILE_USER_NAME" ]; then
    install -d -m 755 "$SSH_AUTH_KEYS_DIR"
    install -m 644 "$SSH_AUTH_KEYS_DIR/$PROFILE_USER_NAME" "$SSH_AUTH_KEYS_DIR/root"
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

ndh::logger:command:run "@loggerTag@" main "$@"
