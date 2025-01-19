{ pkgs, lib, ... }:
{

  programs.kitty = {
    enable = true;
    package = pkgs.kitty;
    font = {
      package = pkgs.powerline-fonts;
      name = "JetBrains Mono";
    };
    settings = {
      font_family = "JetBrains Mono";
      bold_font = "auto";
      italic_font = "auto";
      bold_italic_font = "auto";
      font_size = 14.0;
      adjust_line_height = 0;
      adjust_column_width = 0;
      disable_ligatures = "never";
      box_drawing_scale = "0.001, 1, 1.5, 2";
      cursor_shape = "block";
      shell_integration = "no-cursor";
      cursor_blink_interval = -1;
      cursor_stop_blinking_after = 15.0;
      scrollback_lines = 2000;
      scrollback_pager = "less --chop-long-lines --RAW-CONTROL-CHARS +INPUT_LINE_NUMBER";
      scrollback_pager_history_size = 0;
      wheel_scroll_multiplier = 5.0;
      touch_scroll_multiplier = 1.0;
      mouse_hide_wait = 3.0;
      url_style = "curly";
      open_url_modifiers = "kitty_mod";
      open_url_with = "default";
      copy_on_select = "no";
      strip_trailing_spaces = "smart";
      rectangle_select_modifiers = "ctrl+alt";
      terminal_select_modifiers = "shift";
      select_by_word_characters = ":@-./_~?&=%+#";
      click_interval = -1.0;
      focus_follows_mouse = "no";
      pointer_shape_when_grabbed = "arrow";
      repaint_delay = 10;
      input_delay = 3;
      sync_to_monitor = "yes";
      enable_audio_bell = "yes";
      visual_bell_duration = 0.0;
      window_alert_on_bell = "yes";
      bell_on_tab = "yes";
      command_on_bell = "none";
      remember_window_size = "yes";
      initial_window_width = 640;
      initial_window_height = 400;
      enabled_layouts = "*";
      window_resize_step_cells = 2;
      window_resize_step_lines = 2;
      window_border_width = 1.0;
      draw_minimal_borders = "yes";
      window_margin_width = 0.0;
      single_window_margin_width = -1000.0;
      window_padding_width = 0.0;
      placement_strategy = "center";
      inactive_text_alpha = 1.0;
      hide_window_decorations = "no";
      resize_debounce_time = 0.1;
      resize_draw_strategy = "static";
      tab_bar_edge = "bottom";
      tab_bar_margin_width = 0.0;
      tab_bar_style = "fade";
      tab_bar_min_tabs = 2;
      tab_switch_strategy = "previous";
      tab_fade = "0.25 0.5 0.75 1";
      tab_separator = " ┇";
      tab_title_template = "{title}";
      active_tab_title_template = "none";
      active_tab_font_style = "bold-italic";
      inactive_tab_font_style = "normal";
      background_opacity = 1.0;
      dynamic_background_opacity = "no";
      dim_opacity = 0.75;
      shell = ".";
      editor = ".";
      close_on_child_death = "no";
      allow_remote_control = "no";
      update_check_interval = 24;
      startup_session = "none";
      clipboard_control = "write-clipboard write-primary";
      term = "xterm-256color";
      macos_option_as_alt = "yes";
      macos_hide_from_tasks = "no";
      macos_quit_when_last_window_closed = "no";
      macos_window_resizable = "yes";
      macos_thicken_font = 0;
      macos_traditional_fullscreen = "no";
      macos_show_window_title_in = "all";
      macos_custom_beam_cursor = "no";
      linux_display_server = "auto";

      # Theme settings
      foreground = "#000000";
      background = "#fbf7f0";
      selection_foreground = "#000000";
      selection_background = "#bcbcbc";
      cursor = "#7B1A36";
      cursor_text_color = "#fbf7f0";
      active_border_color = "#193668";
      inactive_border_color = "#9f9f9f";
      active_tab_foreground = "#000000";
      active_tab_background = "#c9b8b1";
      inactive_tab_foreground = "#585858";
      inactive_tab_background = "#dfd6cd";
      color0 = "#000000";
      color8 = "#585858";
      # Add the remaining color settings from current-theme.conf
    };
  };

}