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
  # Use the wrapped activation logger packaged into the system closure
  activationLogger = config.activation.loggerScript;
  activationTag = "nixos.activationScripts.sshGroupKeys";
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
    sshGroupKeys = {
      text = builtins.readFile (
        pkgs.replaceVars ./openssh.d/activation.sh {
          keysDir = config.opensshPolicy.keysDir;
          hostname = hostname;
          sshKeygen = "${pkgs.openssh}/bin/ssh-keygen";
          principalsCommand = config.opensshPolicy.canonicalPrincipalsCommandName;
          groupCommand = config.opensshPolicy.canonicalGroupKeysCommandName;
          principalsScript = principalsScriptStore;
          groupKeysScript = groupKeysScriptStore;
          activationLogger = activationLogger;
          activationTag = activationTag;
        }
      );
    };
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
