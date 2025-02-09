{ config, pkgs, ... }:

let
  # Debug function that both traces and returns its input
  debugTrace = x: builtins.trace "Debug: profile = ${builtins.toJSON x}" x;

  profile = config._module.specialArgs.profile;
  debuggedProfile = debugTrace profile;

  profileName = profile.name;
  hostName = profile.host.name; 
  userName = profile.user.name;

  # Command to filter and sign keys based on profile and host
  yamlHostKeys = pkgs.runCommand "ssh-signed-keys.yaml" {
    buildInputs =
      [ pkgs.coreutils-full pkgs.yq-go pkgs.openssh pkgs.bash pkgs.gnused ];
  } ''
    ${./ssh-add-keys.sh} "${debuggedProfile.name}" "${debuggedProfile.host.name}" "${./ssh.d/keys.yaml}" "$out" 
    #${./ssh-add-keys.sh} "${profileName}" "${hostName}" "${./ssh.d/keys.yaml}" "$out" 
  '';

  # Script to extract host keys and CA public key from keys.yaml
  keysDir = pkgs.runCommand "${userName}::ssh-host-keys.d" {
    buildInputs = [ pkgs.coreutils-full pkgs.yq-go ];
  } ''
    ${./ssh-extract-keys.sh} "${yamlHostKeys}" "$out"
  '';

 # Script to retrieve known hosts including CA public key
  knownHostsScript = pkgs.writeScript "known-hosts-script" ''
    #!${pkgs.bash}/bin/bash -euxo pipefail
    exec 2> ~/.local/var/known-hosts.log
    sed 's/^/@cert-authority *,principals="admin,staff" /' ${keysDir}/*-ca.pub
    exit 0
  '';

in {
  imports = [ ./ssh-add-keys.nix ];

  ssh-add-keys = {
    enable = true;
    keyFile = yamlHostKeys;
  };

  home.file.".ssh" = {
    source = pkgs.lib.mkForce (pkgs.lib.cleanSourceWith {
      src = ./ssh.d;
      filter = path: type: !(builtins.match ".*/keys.yaml" path != null);
    });
    recursive = true;
  };

  home.file.".ssh/keys.yaml" = { source = yamlHostKeys; };

  xdg.stateFile."ssh-keys.d" = {
    source = keysDir;
    recursive = true;
  };

  programs.ssh = {
    enable = true;
    includes = [ "config.d/*" ];
    forwardAgent = true;
    addKeysToAgent = "no";
    controlMaster = "auto";
    controlPersist = "yes";
    controlPath = "${config.home.homeDirectory}/.ssh/master-%C";

      # Add these new options
    extraConfig = ''
      KnownHostsCommand ${knownHostsScript}
      EnableSSHKeysign yes
    '';
  };



}
