{
  config,
  pkgs,
  lib,
  ...
}:

let
  dollar = "$";
  hostname =
    if config.networking.hostName != "" then config.networking.hostName else "nix-darwin-home";
  # Reuse existing host key generated/managed by NixOS (ed25519 preferred)
  hostKeyPath = "/etc/ssh/ssh_host_ed25519_key"; # runtime path consumed by sshd
  hostCertPath = null; # Add signed host cert later if desired
  keysDir = config.opensshPolicy.keysDir;
  caPublicKeyPath = "${keysDir}/mammoth_skate-ca.pub"; # ensure provisioning populates (activation below copies if present)
  principalsScriptStore = pkgs.writeText "ssh-authorized-principals-command.sh" (
    builtins.readFile ../../common/ssh/authorized-principals-command.sh
  );
  groupKeysScriptStore = pkgs.writeText "ssh-group-authorized-keys-command.sh" (
    builtins.readFile ../../common/ssh/ssh-group-authorized-keys.sh
  );
in
{
  imports = [ ../../common/openssh-policy.nix ];

  opensshPolicy = {
    enable = true;
    trustedCAPath = caPublicKeyPath;
    principalsCommandSource = principalsScriptStore;
    groupKeysCommandSource = groupKeysScriptStore;
    hostKeyPaths = [ hostKeyPath ];
  };

  services.openssh = {
    enable = true;
    authorizedKeysFiles = lib.mkForce config.opensshPolicy.authorizedKeysFiles;
    settings = config.opensshPolicy.settings // {
      UsePAM = true;
      # Allow client to specify which address to bind for remote forwardsssh
      GatewayPorts = "clientspecified";
    };
    # Render shared daemon Include globs
    extraConfig =
      (
        let
          lines = builtins.map (g: "Include ${g}") config.opensshPolicy.includeDaemonGlobs;
        in
        lib.concatStringsSep "\n" lines + "\n"
      )
      + ''
        # Enable remote forwarding of Unix domain sockets (for GPG agent forwarding)
        StreamLocalBindUnlink yes
        AllowStreamLocalForwarding yes
      '';
  };

  # OpenSSH client configuration: allow includes for drop-ins under /etc/ssh/ssh_config.d
  programs.ssh = {
    extraConfig =
      let
        lines = builtins.map (g: "Include ${g}") config.opensshPolicy.includeClientGlobs;
      in
      lib.concatStringsSep "\n" lines + "\n";
  };

  # Ensure the group authorized keys directory exists and create keys
  system.activationScripts = {
    sshGroupKeys = ''
      : "Ensure directory for authorized keys exists"
      SSH_AUTH_KEYS_DIR=/etc/ssh/authorized_keys.d
      install -d -m 755 "$SSH_AUTH_KEYS_DIR"

      : "Ensure directory for SSH keys exists (for CA key + any custom keys)"
      SSH_KEYS_DIR=${config.opensshPolicy.keysDir}
      install -d -m 755 "$SSH_KEYS_DIR"

      : "Generate and symlink a build user key into the authorized keys directory (idempotent)"
      SSH_KEY_NIXBLD="$SSH_KEYS_DIR/nixbld"
      if [ ! -f "$SSH_KEY_NIXBLD" ]; then
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f "$SSH_KEY_NIXBLD" -N "" -C "nixbld@${hostname}"
        chmod a+r "${dollar}{SSH_KEY_NIXBLD}".pub
        ln -sf "${dollar}{SSH_KEY_NIXBLD}.pub" "$SSH_AUTH_KEYS_DIR/nixbld"
      fi

      : "If a CA public key was staged somewhere (e.g., in /run or a user profile), copy it into place (placeholder logic)"
      if [ -f "$SSH_KEYS_DIR/mammoth_skate-ca.pub" ]; then
        chmod 644 "$SSH_KEYS_DIR/mammoth_skate-ca.pub"
      fi

      : "Install a root-owned copy of AuthorizedKeysCommand (group aggregation) and principals command"
      install -m 555 ${groupKeysScriptStore} /etc/ssh/${config.opensshPolicy.canonicalGroupKeysCommandName}
      if [ ! -e /etc/ssh/ssh-group-authorized-keys ]; then
        ln -s ${config.opensshPolicy.canonicalGroupKeysCommandName} /etc/ssh/ssh-group-authorized-keys
      fi
      install -m 555 ${principalsScriptStore} /etc/ssh/${config.opensshPolicy.canonicalPrincipalsCommandName}
      if [ ! -e /etc/ssh/authorized-principals-command ]; then
        ln -s ${config.opensshPolicy.canonicalPrincipalsCommandName} /etc/ssh/authorized-principals-command
      fi

      : "Ensure drop-in include directories exist"
      install -d -m 755 /etc/ssh/sshd_config.d
      install -d -m 755 /etc/ssh/ssh_config.d
    '';
  };

  # ssh non-interactive session finds the setuid sudo via /bin or /usr/bin
  systemd.tmpfiles.rules = [
    "L+ /bin/sudo - - - - /run/wrappers/bin/sudo"
    "L+ /usr/bin/sudo - - - - /run/wrappers/bin/sudo"
    "L+ /bin/bash - - - - /run/current-system/sw/bin/bash"
  ];

  # Ensure all systemd services (including sshd) inherit a wrapper-first PATH
  systemd.globalEnvironment.PATH = config.opensshPolicy.setEnvPath;
}
