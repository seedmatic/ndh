{ config, pkgs, ... }:

let
  dollar = "$";
  groupKeysScript = pkgs.writeScript "group-keys.sh" ''
    #!/bin/sh
    set -e

    USER="${dollar}{1}"
    [ -z "${dollar}{USER}" ] && exit 1

    for GROUP in $(id -nG "${dollar}{USER}"); do
      KEY_FILE="/etc/ssh/authorized_keys.d/${dollar}{GROUP}"
      [ -r "${dollar}{KEY_FILE}" ] && cat "${dollar}{KEY_FILE}"
    done
  '';

  # Use the configured hostname or default to "nix-darwin-home"
  hostname = if config.networking.hostName != "" then config.networking.hostName else "nix-darwin-home"; 
in
{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      AuthorizedKeysFile = "%h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u";
      AuthorizedKeysCommand = "/etc/ssh/group-keys.sh %u";
      AuthorizedKeysCommandUser = "nobody";
    };
  };

  # Ensure the group authorized keys directory exists and create keys
  system.activationScripts = {
    sshGroupKeys = ''
      # Ensure directory for authorized keys exists
      SSH_AUTH_KEYS_DIR=/etc/ssh/authorized_keys.d
      mkdir -p "$SSH_AUTH_KEYS_DIR"
      chmod 755 "$SSH_AUTH_KEYS_DIR"

      # Ensure directory for SSH keys exists
      SSH_KEYS_DIR=/etc/ssh/keys.d
      mkdir -p "$SSH_KEYS_DIR"
      chmod 755 "$SSH_KEYS_DIR"

      # Generate and symlink the public key into the authorized keys directory
      SSH_KEY_NIXBLD="$SSH_KEYS_DIR/nixbld"
      if [ ! -f "$SSH_KEY_NIXBLD" ]; then
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f "$SSH_KEY_NIXBLD" -N "" -C "nixbld@${hostname}"
        chmod a+r "${dollar}{SSH_KEY_NIXBLD}".pub
        ln -sf "${dollar}{SSH_KEY_NIXBLD}.pub" "$SSH_AUTH_KEYS_DIR/nixbld"
      fi

      # Copy scripts with the right ownership
      cp ${groupKeysScript} /etc/ssh/group-keys.sh
      chmod 555 /etc/ssh/group-keys.sh
    '';
  };
}
