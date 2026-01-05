# This is the home configuration of the user.
{
  config,
  pkgs,
  lib,
  floxEnv ? null,
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
    if config ? _module && config._module ? specialArgs then
      config._module.specialArgs
    else
      specialArgs;

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

  activationLoggerArgs =
    if specialArgsResolved ? activationLogger then
      specialArgsResolved.activationLogger
    else
      throw "specialArgs.activationLogger is required";
  activationLogger = activationLoggerArgs.script;
  activationTagFixConfigOwnership = "home-manager.activationScripts.${userName}.fixConfigOwnership";

  baseHomePackages = with pkgs; [
    aider-chat
    alejandra
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
    ffmpeg
    findutils
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
    hurl
    jdk
    k9s
    kpt
    krew
    kubectl
    kubectx
    kubernetes-helm
    kustomize
    #     lazydocker
    luajit
    minikube
    mmv
    neofetch
    nix
    nixfmt-classic
    nixpkgs-fmt
    nodejs
    parallel
    passExtensions.pass-otp
    passExtensions.pass-audit
    passExtensions.pass-update
    passExtensions.pass-import
    passExtensions.pass-checkup
    passExtensions.pass-genphrase
    podman
    # podman-desktop
    poetry
    pnpm
    pre-commit
    # rancher-desktop
    ranger
    rclone
    rsync
    shellcheck
    sops
    stylua
    tig
    tree
    treefmt
    trivy
    vault-bin
    yarn
    yamllint
    yq-go
    zellij
    zsh
  ];

in
{

  imports = [
    ./avahi.nix
    ./bat.nix
    ./cache-tokens.nix
    ./cachix-agent.nix
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
    ./java.nix
    ./keychain.nix
    # ./kitty.nix
    ./shadow-repositories.nix
    # ./nushell.nix
    ./password-store.nix
    ./socket-vmnet.nix
    ./shell.nix
    ./starship.nix
    ./ssh.nix
    ./ssh-keys.nix
    ./ssh-tailnet-hosts.nix
    ./ssh-keychain-removal.nix
    ./tldr.nix
    ./tmate.nix
    ./tmux.nix
    ./vscode
    ./xdg.nix
  ];

  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 1d";
  };

  home = {
    homeDirectory = lib.mkForce homeDirectory; # Ensure home directory is set

    stateVersion = "25.05";

    sessionPath = [
      "${homeDirectory}/.rd/bin"
      "${homeDirectory}/.local/bin"
      "${homeDirectory}/.krew/bin"
    ];

    # Define package definitions for current user environment
    packages = baseHomePackages;

    activation.fixConfigOwnership = lib.hm.dag.entryBefore [ "writeBoundary" ] (
      builtins.readFile (
        pkgs.replaceVars ./default.d/fix-config-ownership.sh {
          activationLogger = activationLogger;
          activationTag = activationTagFixConfigOwnership;
        }
      )
    );

  };

  targets.genericLinux.enable = false;

  programs = {

    home-manager.enable = lib.mkDefault true;

    cache-tokens.enable = lib.mkDefault true;

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
  }
  // (
    if pkgs.stdenv.isDarwin then
      {
        # Disable cachix-agent to avoid conflicts with our cache-tokens module
        # cachix-agent = {
        #   enableLaunchdAgent = true;
        #   name = "nix-community";
        #   credentialsFile = ./cachix-agent.dhall;
        # };
      }
    else
      { }
  );
}
