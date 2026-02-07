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
  profile = config.profile or { name = "default"; host = { hostName = hostname; }; };
  profileName = profile.name;
  hostIdent = if (profile.host ? hostAlias && profile.host.hostAlias != null && profile.host.hostAlias != "") then profile.host.hostAlias else profile.host.hostName;
  # Reuse existing host key generated/managed by NixOS (ed25519 preferred)
  hostKeyPath = "/etc/ssh/ssh_host_ed25519_key"; # runtime path consumed by sshd
  hostCertPath = null; # Add signed host cert later if desired
  keysDir = config.opensshPolicy.keysDir;
  caPublicKeyPath = "${keysDir}/trusted-user-ca.pub"; # generated from all *-ca.pub keys in keysDir
  caKeysYaml = pkgs.runCommand "ssh-ca-keys.yaml"
    {
      buildInputs = [ pkgs.bash pkgs.coreutils-full pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.openssh pkgs.yq-go pkgs.hostname ];
    }
    ''
      bash ${../../home-manager/ssh-generate-keys-yaml.sh} "${profileName}" "${hostIdent}" "${../../home-manager/ssh.d/keys.yaml}" "$out"
      yq eval '(.keys | with_entries(select((.value.usage // []) | contains(["ssh-authority"])))) as $k | {"keys": $k}' -i "$out"
      # Drop any private material for CA keys (public CA only)
      yq eval '(.keys | with_entries(.value.private = null)) as $k | {"keys": $k}' -i "$out"
    '';
  caKeysDir = pkgs.runCommand "ssh-ca-keys.d"
    {
      buildInputs = [ pkgs.bash pkgs.coreutils-full pkgs.yq-go pkgs.gnused pkgs.gnugrep pkgs.gawk pkgs.gettext ];
    }
    ''
      ${pkgs.bash}/bin/bash ${../../home-manager/ssh-extract-keys.sh} "${caKeysYaml}" "$out"
    '';
  principalsScriptStore = pkgs.writeText "ssh-authorized-principals-command.sh" (
    builtins.readFile ../../common/ssh/authorized-principals-command.sh
  );
  groupKeysScriptStore = pkgs.replaceVars ../../common/ssh/ssh-group-authorized-keys.sh {
    authorizedKeysDir = config.opensshPolicy.authorizedKeysDir;
  };
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
    
    # Force IPv4 only for SSH server
    extraSettings = {
      AddressFamily = "inet";
    };
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
      ''
        Host *
          AddressFamily inet
          ServerAliveInterval 30
          ServerAliveCountMax 3
      ''
      + (
        let
          lines = builtins.map (g: "Include ${g}") config.opensshPolicy.includeClientGlobs;
        in
        "\n" + lib.concatStringsSep "\n" lines + "\n"
      );
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
          caKeysDir = caKeysDir;
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
