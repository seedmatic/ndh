{ config, pkgs, lib, ... }:

let
  dollar = "$";
  hostname = if config.networking.hostName != "" then config.networking.hostName else "nix-darwin-home";
  # Reuse existing host key generated/managed by NixOS (ed25519 preferred)
  hostKeyPath = "/etc/ssh/ssh_host_ed25519_key"; # runtime path consumed by sshd
  hostCertPath = null; # Add signed host cert later if desired
  caPublicKeyPath = "/etc/ssh/keys.d/mammoth_skate-ca.pub"; # ensure provisioning populates (activation below copies if present)
  principalsScriptStore = pkgs.writeText "ssh-authorized-principals-command.sh" (builtins.readFile ../../common/ssh/authorized-principals-command.sh);
  groupKeysScriptStore = pkgs.writeText "ssh-group-authorized-keys-command.sh" (builtins.readFile ../../common/ssh/ssh-group-authorized-keys.sh);
in
{
  imports = [ ../../common/openssh-policy.nix ];

  opensshPolicy = {
    enable = true;
    passwordAuthentication = false;
    permitRootLogin = "no";
    trustedCAPath = caPublicKeyPath;
    principalsFilePath = "%h/.ssh/authorized_principals";
  principalsCommandSource = principalsScriptStore;
    principalsCommandUser = "nobody";
    groupDirectory = "/etc/ssh/authorized_keys.d";
  groupCommandUser = "nobody";
  groupKeysCommandSource = groupKeysScriptStore;
    authorizedKeysFiles = [ "%h/.ssh/authorized_keys" "/etc/ssh/authorized_keys.d/%u" ];
    hostKeyPaths = [ hostKeyPath ];
    extraSettings = {
      # Ensure sshd sessions search /run/wrappers/bin first.
      SetEnv = "PATH=/run/wrappers/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    };
  };

  services.openssh = {
    enable = true;
    authorizedKeysFiles = lib.mkForce config.opensshPolicy.authorizedKeysFiles;
    settings = config.opensshPolicy.settings;
  };

  # Ensure the group authorized keys directory exists and create keys
  system.activationScripts = {
    sshGroupKeys = ''
      # Ensure directory for authorized keys exists
      SSH_AUTH_KEYS_DIR=/etc/ssh/authorized_keys.d
      install -d -m 755 "$SSH_AUTH_KEYS_DIR"

      # Ensure directory for SSH keys exists (for CA key + any custom keys)
      SSH_KEYS_DIR=/etc/ssh/keys.d
      install -d -m 755 "$SSH_KEYS_DIR"

      # Generate and symlink a build user key into the authorized keys directory (idempotent)
      SSH_KEY_NIXBLD="$SSH_KEYS_DIR/nixbld"
      if [ ! -f "$SSH_KEY_NIXBLD" ]; then
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f "$SSH_KEY_NIXBLD" -N "" -C "nixbld@${hostname}"
        chmod a+r "${dollar}{SSH_KEY_NIXBLD}".pub
        ln -sf "${dollar}{SSH_KEY_NIXBLD}.pub" "$SSH_AUTH_KEYS_DIR/nixbld"
      fi

      # If a CA public key was staged somewhere (e.g., in /run or a user profile), copy it into place (placeholder logic)
      if [ -f "$SSH_KEYS_DIR/mammoth_skate-ca.pub" ]; then
        chmod 644 "$SSH_KEYS_DIR/mammoth_skate-ca.pub"
      fi

      # Install a root-owned copy of AuthorizedKeysCommand (group aggregation) and principals command
      install -m 555 ${groupKeysScriptStore} /etc/ssh/${config.opensshPolicy.canonicalGroupKeysCommandName}
      if [ ! -e /etc/ssh/ssh-group-authorized-keys ]; then
        ln -s ${config.opensshPolicy.canonicalGroupKeysCommandName} /etc/ssh/ssh-group-authorized-keys
      fi
      install -m 555 ${principalsScriptStore} /etc/ssh/${config.opensshPolicy.canonicalPrincipalsCommandName}
      if [ ! -e /etc/ssh/authorized-principals-command ]; then
        ln -s ${config.opensshPolicy.canonicalPrincipalsCommandName} /etc/ssh/authorized-principals-command
      fi
    '';
  };
}
