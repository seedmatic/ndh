# This is the home configuration of the user.
{
  config,
  pkgs,
  lib,
  floxEnv ? null,
  worktreePath,
  # When imported from the system layer we pass `profile` directly; when
  # evaluated inside home-manager proper, it is available via
  # `config._module.specialArgs.profile`.
  profile ? null,
  # Allow direct imports to provide specialArgs when _module.specialArgs is absent
  specialArgs ? { },
  ...
}:
let
  specialArgsResolved =
    (if config ? _module && config._module ? specialArgs then config._module.specialArgs else { })
    // specialArgs;

  ndhContext =
    if
      specialArgsResolved ? ndh
      && specialArgsResolved.ndh != null
      && specialArgsResolved.ndh ? context
      && specialArgsResolved.ndh.context != null
    then
      specialArgsResolved.ndh.context
    else
      null;

  nixBashTrampoline =
    if ndhContext != null && ndhContext ? nixBashTrampoline then
      "${ndhContext.nixBashTrampoline}"
    else
      "${worktreePath.runtimeFile "modules/.common.d/shell.d/nix-bash-trampoline.sh"}";

  ndhArgs =
    if specialArgsResolved ? ndh && specialArgsResolved.ndh != null then
      specialArgsResolved.ndh
    else
      { };

  ndhLoggerArgs = if ndhArgs ? logger && ndhArgs.logger != null then ndhArgs.logger else { };

  resolvedProfile =
    if profile != null then profile else lib.attrByPath [ "profile" ] null specialArgsResolved;

  homeUsernameFallback = lib.attrByPath [ "home" "username" ] null config;
  homeDirectoryFallback = lib.attrByPath [ "home" "homeDirectory" ] null config;

  userName =
    if resolvedProfile != null && resolvedProfile ? user && resolvedProfile.user ? name then
      resolvedProfile.user.name
    else
      homeUsernameFallback;

  homeDirectory =
    if resolvedProfile != null && resolvedProfile ? user && resolvedProfile.user ? home then
      resolvedProfile.user.home
    else
      homeDirectoryFallback;

  homeDirectoryString = toString homeDirectory;
  homeDirectorySafe =
    if pkgs.stdenv.isLinux then
      "/home/${userName}"
    else if pkgs.stdenv.isDarwin && builtins.match ".* .*" homeDirectoryString != null then
      "/Users/${userName}"
    else
      homeDirectoryString;
  systemCaBundle =
    if pkgs.stdenvNoCC.isDarwin then "/etc/ssl/cert.pem" else "/etc/ssl/certs/ca-bundle.crt";

  loggerArgs =
    if ndhLoggerArgs != { } then ndhLoggerArgs else throw "specialArgs.ndh.logger is required";
  loggerTagFixConfigOwnership = "home-manager.activationScripts.${userName}.fixConfigOwnership";

  resolvedImports = [
    ./aws.nix
    ./avahi.nix
    ./bat.nix
    ./chromium.nix
    ./dircolors.nix
    ./direnv.nix
    ./dotfiles
    ./emacs.nix
    # ./firefox.nix
    ./flox-direnv.nix
    ./fzf.nix
    ./git.nix
    ./gh.nix
    ./gpg.nix
    ./incus-remote.nix
    ./java.nix
    ./keychain.nix
    # ./kitty.nix
    ./shadow-repositories.nix
    # ./nushell.nix
    ./password-store.nix
    ./shell.nix
    ./starship.nix
    ./ssh.nix
    ./ssh-keys.nix
    ./ssh-tailnet-hosts.nix
    ./ssh-keychain-removal.nix
    ./tldr.nix
    ./tmate.nix
    ./tmux.nix
    ./xdg.nix
  ];

  baseHomePackages = with pkgs; [
    awscli2
    avahi
    cachix
    cirrus-cli
    comma
    coreutils-full
    curl
    diffutils
    direnv
    docker
    docker-compose
    findutils
    flox
    flyctl
    gawk
    gdu
    gh
    git-workspace
    gnugrep
    gnupg
    gnused
    helm-docs
    httpie
    jdk
    k9s
    krew
    kubectl
    kubectx
    kubernetes-helm
    kustomize
    nix
    nixfmt
    nixpkgs-fmt
    nodejs
    parallel
    # pass + its extensions are declared once via pass.withExtensions in
    # password-store.nix (the canonical, extension-bundling path) — no standalone
    # passExtensions.* here, which only duplicated a subset of that closure.
    podman
    # podman-desktop
    # poetry
    pnpm
    # pre-commit
    # rancher-desktop
    # ranger
    rclone
    rsync
    shellcheck
    sops
    tig
    tree
    treefmt
    # trivy
    vault-bin
    yarn
    yamllint
    yq-go
    zellij
    zsh
  ];

in
{

  imports = resolvedImports;

  # Operator Incus identity for the nxmatic account on every node: derives its
  # remote from the host's own VM identity (<host>-nixos), idempotent, and
  # non-fatal when the server is unreachable. mkDefault so a host can opt out.
  ndh.incusRemote.enable = lib.mkDefault true;

  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 1d";
  };

  home = {
    homeDirectory = lib.mkForce homeDirectorySafe; # Ensure home directory is set and avoid space-splitting activation issues on Darwin

    stateVersion = "25.11";

    # PATH is owned by ./shell.nix (`home.sessionPath = coreShellPath`).
    # Don't add entries here — keep the list in one place.

    # Define package definitions for current user environment
    packages = baseHomePackages;

    # Canonical TLS trust store path for user-space tooling (git, curl, nix,
    # plugin managers, etc.). Keep one source of truth per platform.
    sessionVariables = {
      SSL_CERT_FILE = systemCaBundle;
      NIX_SSL_CERT_FILE = systemCaBundle;
      GIT_SSL_CAINFO = systemCaBundle;
      CURL_CA_BUNDLE = systemCaBundle;
    };

    activation.fixConfigOwnership =
      let
        fixConfigOwnershipScript = pkgs.replaceVars ./default.d/fix-config-ownership.sh {
          nixBashTrampoline = nixBashTrampoline;
          loggerTag = loggerTagFixConfigOwnership;
        };
      in
      lib.hm.dag.entryBefore [ "writeBoundary" ] ''
        ${pkgs.bash}/bin/bash ${fixConfigOwnershipScript}
      '';

  };

  targets.genericLinux.enable = false;

  programs = {

    home-manager.enable = lib.mkDefault true;

    zsh.enable = lib.mkDefault true;

    dircolors.enable = lib.mkDefault true;

    go.enable = lib.mkDefault true;

    gpg.enable = lib.mkDefault false;

    password-store.enable = lib.mkDefault true;

    git.enable = lib.mkDefault true;

    htop.enable = lib.mkDefault true;

    jq.enable = lib.mkDefault true;

    java.enable = lib.mkDefault true;

    k9s.enable = lib.mkDefault true;

    lazygit.enable = lib.mkDefault true;

    less.enable = lib.mkDefault true;

    man.enable = lib.mkDefault true;

    nix-index.enable = lib.mkDefault true;

    pandoc.enable = lib.mkDefault true;

    ripgrep.enable = lib.mkDefault true;

    starship.enable = lib.mkDefault true;

    yt-dlp.enable = lib.mkDefault false;

    zoxide.enable = lib.mkDefault true;

    zellij.enable = lib.mkDefault true;
  };

  services = {
    # Enable the emacs daemon
    emacsDaemon = {
      enable = true;
    };

    # Enable shadowing folders
    shadowRepositories = {
      enable = false;

      mountPoints = [
        "/Volumes/GitHub/HylandSoftware/hxpr"
        "/Volumes/GitHub/nuxeo/nos"
      ];
    };
  };
}
