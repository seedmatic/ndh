{...}: {
  programs.tmux = {
    enable = true;
    extraConfig = ''
     set-option -g default-command "reattach-to-user-namespace -l zsh"
    '';
  };
}
