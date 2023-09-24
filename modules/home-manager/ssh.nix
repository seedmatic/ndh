{...}: {
  programs.ssh = {
    enable = true;
    includes = ["config.d/*"];
    forwardAgent = true;
    controlPath = "~/.ssh/master-%C";
  };
}
