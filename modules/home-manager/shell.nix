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
  ]
  ++ lib.optionals pkgs.stdenvNoCC.isLinux [
    "/run/wrappers/bin"
  ]
  ++ [
    "/run/current-system/sw/bin"
    "/etc/profiles/per-user/${userName}/bin"
  ];
  # Use platform-provided logger script from specialArgs (required)
  logger = config._module.specialArgs.ndh.logger.script;
  loggerTagZdotdir = "home-manager.activationScripts.${userName}.zdotdir";
  zshInitContent = pkgs.replaceVars ./shell.d/zsh-init.zsh {
    linuxWrappersLine = lib.optionalString pkgs.stdenvNoCC.isLinux "/run/wrappers/bin";
  };
in
{
  programs.zsh = {
    enable = true;

    profileExtra = ''
      ${lib.optionalString pkgs.stdenvNoCC.isLinux "[[ -e /etc/profile ]] && source /etc/profile"}
    '';

    envExtra = builtins.readFile ./shell.d/zshenv.zsh;

    initContent = builtins.readFile zshInitContent;
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
        bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
        caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        logger = logger;
        loggerTag = loggerTagZdotdir;
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
