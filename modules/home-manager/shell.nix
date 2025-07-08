{
  lib,
  pkgs,
  ...
}: {
  programs.zsh = {
    enable = true;

    profileExtra = ''
      ${lib.optionalString pkgs.stdenvNoCC.isLinux "[[ -e /etc/profile ]] && source /etc/profile"}
    '';

    envExtra = builtins.readFile ./shell/zshenv.zsh;

    initContent = ''
      if [[ "$TERM_PROGRAM" == "vscode" ]]; then
        codepath=/usr/local/bin/code
        if [[ -x "$codepath" ]]; then
          source "$($codepath --locate-shell-integration-path zsh)"
        else
          "You should run in vscode the command: install 'code' command in path"
          exit 1
        fi
      else
        source "$ZDOTDIR/rcs/zshrc.zsh"
      fi
    '';
  };

  programs.bash = {
    enable = true;

    bashrcExtra = ''
      export PATH=/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:$PATH
    '';
  };

  home.activation.zdotdir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -d "$HOME/.config/zsh/.git" ]; then
      git clone --depth=1 https://github.com/nxmatic/zdotdir.git "$HOME/.config/zsh"
    else
      git -C "$HOME/.config/zsh" pull --ff-only
    fi
  '';

  home.sessionVariables.ZDOTDIR = "$HOME/.config/zsh";
}
