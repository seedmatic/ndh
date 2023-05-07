{pkgs, ...}: let
  theme = builtins.readFile ./theme.conf;
in {
  programs.kitty = {
    enable = true;
    package = pkgs.kitty;
    font = {
      package = pkgs.powerline-fonts;
      name = "Hack Nerd Font Mono";
    };
    theme = "One Dark";
    settings = {
      bold_font = "auto";
      italic_font = "auto";
      bold_italic_font = "auto";
      font_size = 12;
      strip_trailing_spaces = "smart";
      enable_audio_bell = "no";
      term = "xterm-kitty";
      macos_titlebar_color = "background";
      macos_option_as_alt = "yes";
      scrollback_lines = 10000;
      shell_integration = "no-cursor";
    };
  };
}
