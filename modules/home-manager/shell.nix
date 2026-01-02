{
  lib,
  pkgs,
  ...
}:
let
  # VS Code shell integration
  # If VS Code is injecting (VSCODE_INJECTION=1), it will handle integration automatically
  # Otherwise, we manually source it for proper shell integration features
  vscodeShellIntegration = shell: ''
    # Only manually source if VS Code hasn't already injected the integration
    if [[ "$TERM_PROGRAM" == "vscode" && -z "$VSCODE_INJECTION" ]]; then
      VSCODE_SHELL_INTEGRATION="$(${lib.meta.getExe pkgs.vscode} --locate-shell-integration-path ${shell} 2>/dev/null)"
      if [[ -n "$VSCODE_SHELL_INTEGRATION" && -f "$VSCODE_SHELL_INTEGRATION" ]]; then
        # Set the variable that the integration script expects when manually sourced
        VSCODE_INJECTION=1
        USER_ZDOTDIR="$ZDOTDIR"
        builtin source "$VSCODE_SHELL_INTEGRATION"
        TERM=xterm-256color
      fi
    fi
  '';
in
{
  programs.zsh = {
    enable = true;

    profileExtra = ''
      ${lib.optionalString pkgs.stdenvNoCC.isLinux "[[ -e /etc/profile ]] && source /etc/profile"}
    '';

    envExtra = builtins.readFile ./shell/zshenv.zsh;

    initContent = ''
      ${vscodeShellIntegration "zsh"}
      source "$ZDOTDIR/rcs/zshrc.zsh"
    '';
  };

  programs.bash = {
    enable = true;

    bashrcExtra = ''
      export PATH=/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:$PATH
    '';
  };

  home.activation.zdotdir = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    builtins.readFile (
      pkgs.replaceVars ./shell.d/zdotdir.sh {
        gitPath = lib.makeBinPath [ pkgs.git ];
        gitBin = "${pkgs.git}/bin/git";
      }
    )
  );

  home.sessionVariables.ZDOTDIR = "$HOME/.config/zsh";

  # Ensure XDG_RUNTIME_DIR is set (not managed by home-manager's xdg module)
  # Must match zdotdir's zshenv.zsh default
  home.sessionVariables.XDG_RUNTIME_DIR = "$HOME/.xdg";
}
