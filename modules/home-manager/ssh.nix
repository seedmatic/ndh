{ config, pkgs, ... }:

let
  profile = config._module.specialArgs.profile;
  profileName = profile.name;
  profileHost = profile.host.name;

  # Command to filter and sign keys based on profile and host
  yamlHostKeys = pkgs.runCommand "signed-keys.yaml" {
      buildInputs = [ pkgs.coreutils-full pkgs.yq-go pkgs.openssh pkgs.bash pkgs.gnused ];
    }
    ''
      ${./ssh-add-keys.sh} ${./ssh.d/keys.yaml} "$out" "${profileName}" "${profileHost}"
    '';
in
{
  imports = [
    ./ssh-add-keys.nix
  ];

  home-manager.ssh-add-keys = {
    enable = true;
    keyFile = yamlHostKeys;
  };

  home.file.".ssh" = {
    source = pkgs.lib.mkForce (
      pkgs.lib.cleanSourceWith {
        src = ./ssh.d;
        filter = path: type: !(builtins.match ".*/keys.yaml" path != null);
      }
    );
    recursive = true;
  };

  home.file.".ssh/keys.yaml" = {
    source = yamlHostKeys;
  };

  programs.ssh = {
    enable = true;
    includes = [ "config.d/*" ];
    forwardAgent = true;
    addKeysToAgent = "yes";
    controlMaster = "auto";
    controlPersist = "yes";
    controlPath = "${config.home.homeDirectory}/.ssh/master-%C";
  };



}