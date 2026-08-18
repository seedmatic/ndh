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
  # Canonical PATH for interactive + non-interactive shells, in priority order.
  # Most-specific first (user-local bin dirs, then HM per-user profile, then
  # system-wide nix profiles, then OS-level wrappers/sw). This is the only
  # place PATH is built — `home.sessionPath` propagates it to login shells,
  # and the shell init scripts (zshenv, zdotdir, zsh-init) deliberately do
  # NOT rebuild this list.
  coreShellPath = [
    "${homeDir}/.local/bin"
    "${homeDir}/.local/share/pnpm"
  ]
  ++ lib.optionals pkgs.stdenvNoCC.isDarwin [
    # Rancher Desktop is a macOS-only install in this fleet.
    "${homeDir}/.rd/bin"
  ]
  ++ [
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

    # Lock the legacy dotDir (the home directory) rather than inheriting the
    # changed default gated on home.stateVersion < "26.05"; adopting the new XDG
    # default would relocate the zsh dotfiles.  Behaviour-preserving; silences the
    # eval warning.
    dotDir = config.home.homeDirectory;

    profileExtra = ''
      ${lib.optionalString pkgs.stdenvNoCC.isLinux "[[ -e /etc/profile ]] && source /etc/profile"}
    '';

    envExtra = builtins.readFile ./shell.d/zshenv.zsh;

    initContent = zshInitContent;
  };

  programs.bash = {
    enable = true;
  };

  # Lock the legacy default (export XDG_* session variables) rather than the
  # 26.05 change gated on home.stateVersion.  Behaviour-preserving; silences the
  # eval warning.
  xdg.userDirs.setSessionVariables = true;

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

  # Make the home directory traversable by the multi-user nix daemon's build
  # users. The rke2lab seed-master store build (sandbox=false) reuses the host
  # `~/.m2` (settings + cached/local artifacts) as a Maven repo tail; the
  # `_nixbld*` user must be able to descend into `$HOME/.m2/...` to read it.
  # Default macOS home perms (0700) block that traversal, so the build fails to
  # see the tail. Grant execute (traverse) only — NOT read — so other users can
  # reach known paths but cannot enumerate the home directory.
  home.activation.ensureHomeTraversable = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    chmod a+x "$HOME"
  '';

  home.activation.zdotdir =
    let
      zdotdirScript = pkgs.replaceVars ./shell.d/zdotdir.sh {
        nixBashTrampoline = nixBashTrampoline;
        caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        loggerTag = loggerTagZdotdir;
        # Drop the upstream-zdotdir hardcoded ~/.local/opt/lima-vm/bin entry
        # (legacy Lima path; the fleet is Tart-only now).
        limaPathStrip = "path=( \${path:#*/.local/opt/lima-vm/bin} )";
      };
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.bash}/bin/bash ${zdotdirScript}
    '';

  # home-manager points zsh's HISTFILE at ${config.xdg.dataHome}/zsh/history
  # (the XDG default) but never creates the directory, so a freshly bootstrapped
  # home has no zsh history until the dir exists.  Create it idempotently.
  home.activation.zshDataDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "${config.xdg.dataHome}/zsh"
  '';

  home.sessionVariables.ZDOTDIR = "$HOME/.config/zsh";

  # Ensure XDG_RUNTIME_DIR is set (not managed by home-manager's xdg module)
  # Must match zdotdir's zshenv.zsh default
  home.sessionVariables.XDG_RUNTIME_DIR = "$HOME/.xdg";
}
