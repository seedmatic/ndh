{ config, pkgs, lib, ... }:

let
  # Debug function that both traces and returns its input
  debugTrace = x: builtins.traceVerbose "Debug: profile = ${builtins.toJSON x}" x;

  profile = config._module.specialArgs.profile;

  profileName = profile.name;
  hostProfile = profile.host;
  userProfile = profile.user;
  userName = "Stephane Lacoin (aka nxmatic)";
  userDescription = userProfile.description;
  userHome = userProfile.home;

  # Command to filter and sign keys based on profile and host
  yamlHostKeys = pkgs.runCommand "ssh-signed-keys.yaml" {
    buildInputs =
      [ pkgs.coreutils-full pkgs.yq-go pkgs.openssh pkgs.bash pkgs.gnused ];
  } ''
    ${./ssh-add-keys.sh} "${profileName}" "${hostProfile.hostAlias}" "${./ssh.d/keys.yaml}" "$out"
  '';

  # Script to extract host keys and CA public key from keys.yaml
  keysDir = pkgs.runCommand "${userName}::ssh-host-keys.d" {
    buildInputs = [ pkgs.coreutils-full pkgs.yq-go ];
  } ''
    ${./ssh-extract-keys.sh} "${yamlHostKeys}" "$out"
  '';

 # Script to retrieve known hosts including CA public key
  knownHostsScript = pkgs.writeScript "known-hosts-script" ''
    #!${pkgs.bash}/bin/bash -euo pipefail
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

  # Deploy keys directly to ~/.ssh/keys.d/ with proper permissions (skip .local/state)
  home.activation.deploySSHKeys = lib.hm.dag.entryAfter ["writeBoundary"] ''
    run install -d -m 700 ~/.ssh/keys.d
    run ${pkgs.rsync}/bin/rsync -avL \
      --chmod=u+w,go-r \
      --chown=$(id -un):$(id -gn) \
      ${keysDir}/ ~/.ssh/keys.d/ || true
  '';

  programs.ssh.extraConfig = ''
    KnownHostsCommand ${knownHostsScript}
    EnableSSHKeysign yes
  '';
}
