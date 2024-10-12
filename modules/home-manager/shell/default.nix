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

    envExtra = builtins.readFile ./zshenv.zsh;

    initExtra = ''
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
  };
}
