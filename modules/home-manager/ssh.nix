{...}: {
  programs.ssh = {
    enable = true;
    includes = ["config.d/*"];
    forwardAgent = true;
    controlPath = "~/.ssh/master-%C";
  };
  home.file.".ssh" = {
    source = ./ssh.d;
    recursive = true;
  };
}
