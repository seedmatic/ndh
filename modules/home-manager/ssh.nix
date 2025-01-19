{ ... }: {

  imports = [
    ./ssh-add-keys.nix
  ];

  home-manager.ssh-add-keys = {
    enable = true;
  };

  home.file.".ssh" = {
    source = ./ssh.d;
    recursive = true;
  };

  programs.ssh = {
    enable = true;
    includes = [ "config.d/*" ];
    forwardAgent = true;
    controlPath = "~/.ssh/master-%C";
  };

}