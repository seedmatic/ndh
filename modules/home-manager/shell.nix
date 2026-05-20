{
  config,
  lib,
  pkgs,
  worktreePath,
  ...
}:
let
  specialArgs =
    if config ? _module && config._module ? specialArgs then config._module.specialArgs else { };
  nixBashTrampoline =
    if
      specialArgs ? ndh && specialArgs.ndh ? context && specialArgs.ndh.context ? nixBashTrampoline
    then
      "${specialArgs.ndh.context.nixBashTrampoline}"
    else
      "${worktreePath.of "modules/.common.d/shell.d/nix-bash-trampoline.sh"}";
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;
  homeDir = config.home.homeDirectory;
  ndhContext =
    if specialArgs ? ndh && specialArgs.ndh != null && specialArgs.ndh ? context then
      specialArgs.ndh.context
    else
      null;
  vmProvider =
    if profile ? host && profile.host ? vmProvider then
      profile.host.vmProvider
    else if ndhContext != null && ndhContext ? vmProvider && ndhContext.vmProvider != null then
      ndhContext.vmProvider
    else
      null;
  limaActive = vmProvider == "lima";
  # Canonical PATH for interactive + non-interactive shells, in priority order.
  # Most-specific first (user-local bin dirs, then HM per-user profile, then
  # system-wide nix profiles, then OS-level wrappers/sw). This is the only
  # place PATH is built — `home.sessionPath` propagates it to login shells,
  # and the shell init scripts (zshenv, zdotdir, zsh-init) deliberately do
  # NOT rebuild this list.
  coreShellPath =
    [
      "${homeDir}/.local/bin"
      "${homeDir}/.local/share/pnpm"
    ]
    ++ lib.optionals limaActive [
      "${homeDir}/.local/opt/lima-vm/bin"
    ]
    ++ [
      "${homeDir}/.rd/bin"
      "${homeDir}/.krew/bin"
      "${homeDir}/.nix-profile/bin"
      "/etc/profiles/per-user/${userName}/bin"
      "/run/current-system/sw/bin"
    ]
    ++ lib.optionals pkgs.stdenvNoCC.isLinux [
      "/run/wrappers/bin"
    ];
  # Use platform-provided logger script from specialArgs (required)
  loggerTagZdotdir = "home-manager.activationScripts.${userName}.zdotdir";
  zshInitContent = builtins.readFile ./shell.d/zsh-init.zsh;
in
{
  programs.zsh = {
    enable = true;

    profileExtra = ''
      ${lib.optionalString pkgs.stdenvNoCC.isLinux "[[ -e /etc/profile ]] && source /etc/profile"}
    '';

    envExtra = builtins.readFile ./shell.d/zshenv.zsh;

    initContent = zshInitContent;
  };

  programs.bash = {
    enable = true;
  };

  # Ensure all interactive shells (including VS Code terminals) receive the
  # core NixOS/Nix profile paths in a consistent order.
  home.sessionPath = coreShellPath;

  # Prune dangling ~/.nix-profile. The XDG-default `nix profile` location
  # ($HOME/.local/state/nix/profiles/profile) is created lazily by the first
  # `nix profile install` invocation; on a freshly-rebuilt host the symlink
  # ~/.nix-profile points at a path that doesn't exist yet. Tools that probe
  # ~/.nix-profile/bin (and the PATH entry above) tolerate a missing path
  # better than a dangling one — remove the broken symlink so behavior is
  # consistent with hosts where the user has used `nix profile install`.
  home.activation.pruneDanglingNixProfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    nixProfileLink="$HOME/.nix-profile"
    if [ -L "$nixProfileLink" ] && [ ! -e "$nixProfileLink" ]; then
      rm -f "$nixProfileLink"
    fi
  '';

  home.activation.zdotdir =
    let
      zdotdirScript = pkgs.replaceVars ./shell.d/zdotdir.sh {
        nixBashTrampoline = nixBashTrampoline;
        caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
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
