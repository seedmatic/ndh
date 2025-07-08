{ config, pkgs, ... }: {
  programs.ssh = {
    enable = true;
    includes = [ "config.d/*" ];
    forwardAgent = true;
    addKeysToAgent = "no";
    controlMaster = "auto";
    controlPersist = "yes";
    controlPath = "${config.home.homeDirectory}/.ssh/master-%C";
    # Add any additional generic SSH config here
  };
}
