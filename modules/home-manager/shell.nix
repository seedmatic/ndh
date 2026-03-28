{
  config,
  lib,
  pkgs,
  ...
}:
let
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;
  coreShellPath = [
    "${config.home.homeDirectory}/.local/bin"
    "${config.home.homeDirectory}/.local/share/pnpm"
    "${config.home.homeDirectory}/.local/opt/lima-vm/bin"
    "${config.home.homeDirectory}/.nix-profile/bin"
    "/run/wrappers/bin"
    "/run/current-system/sw/bin"
    "/etc/profiles/per-user/${userName}/bin"
  ];
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
  # Use platform-provided logger script from specialArgs (required)
  activationLogger = config._module.specialArgs.activationLogger.script;
  activationTagZdotdir = "home-manager.activationScripts.${userName}.zdotdir";
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
      if [[ -r "$ZDOTDIR/rcs/zshrc.zsh" ]]; then
        source "$ZDOTDIR/rcs/zshrc.zsh"
      fi

      # Normalize PATH after external zshrc/plugin mutations.
      # Keep canonical Nix paths and remove stale foreign-home entries.
      typeset -U path
      path=( ''${path:#/Users/stephane.lacoin/*} )
      path=(
        "$HOME/.local/bin"
        "$HOME/.local/share/pnpm"
        "$HOME/.local/opt/lima-vm/bin"
        "$HOME/.nix-profile/bin"
        /run/wrappers/bin
        /run/current-system/sw/bin
        "/etc/profiles/per-user/$USER/bin"
        "''${path[@]}"
      )
      export PATH="''${(j/:/)path}"

      # Avoid autofs trigger on the first-level /net mountpoint, but allow
      # completion once inside /net/<host>/...
      zstyle ':completion:*:paths' ignored-patterns '/net'
      zstyle ':completion:*:(cd|chdir|pushd|popd|ls):*' ignored-patterns '/net'
    '';
  };

  programs.bash = {
    enable = true;
  };

  # Ensure all interactive shells (including VS Code terminals) receive the
  # core NixOS/Nix profile paths in a consistent order.
  home.sessionPath = coreShellPath;

  home.activation.zdotdir =
    let
      zdotdirScript = pkgs.replaceVars ./shell.d/zdotdir.sh {
        gitPath = lib.makeBinPath [ pkgs.git ];
        gitBin = "${pkgs.git}/bin/git";
        caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        activationLogger = activationLogger;
        activationTag = activationTagZdotdir;
      };
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.bash}/bin/bash ${zdotdirScript}
    '';

  home.sessionVariables.ZDOTDIR = "$HOME/.config/zsh";

  # Ensure XDG_RUNTIME_DIR is set (not managed by home-manager's xdg module)
  # Must match zdotdir's zshenv.zsh default
  home.sessionVariables.XDG_RUNTIME_DIR = "$HOME/.xdg";
}
