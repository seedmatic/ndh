{ user, config, pkgs, lib, self, ... }:
let

  toPath = path: if builtins.typeOf path == "string" then /. + path else path;

  userHome = user.home;

  homeDirectory = userHome;

in {

  imports = [
    ./avahi.nix
    ./bat.nix
    ./cachix-agent.nix
  # ./chromium.nix
    ./dircolors.nix
    ./direnv.nix
    ./dotfiles
    ./emacs.nix
  # ./firefox.nix
    ./flox.nix
    ./flox-direnv.nix
    ./fzf.nix
    ./git.nix
    ./gh.nix
    ./gpg.nix
    ./java.nix
    ./keychain.nix
    ./kitty.nix
    ./shadow-repositories.nix
    ./nushell.nix
    ./password-store.nix
    ./shell
    ./ssh.nix
#   ./teleport.nix
    ./tldr.nix
    ./tmate.nix
    ./tmux.nix
    ./vscode
    ./xdg.nix
  ];

  nix.gc = {
    automatic = true;
    frequency = "daily";
    options = "--delete-older-than 1d";
  };

  home = {
    homeDirectory = builtins.traceVerbose "homeDirectory: ${ builtins.typeOf homeDirectory }" homeDirectory;

    stateVersion = "24.11";

    sessionPath = [
      "${homeDirectory}/.rd/bin"
      "${homeDirectory}/.local/bin"
      "${homeDirectory}/.krew/bin"
    ];

    # Define package definitions for current user environment
    packages = with pkgs; [
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
      poetry
      pnpm
      pre-commit
      ranger
      rclone
      rsync
      shellcheck
      sops
      stylua
      sysdo
      teleport
      tig
      tree
      treefmt
      trivy
      vault-bin
      vfkit
      yarn
      yamllint
      yq-go
      zellij
      zsh
    ];
  };

  targets.genericLinux.enable = false;

  programs = {

    home-manager.enable = true;

    bash.enable = true;

    dircolors.enable = true;

    go.enable = true;

    gpg.enable = true;

    password-store.enable = true;

    git.enable = true;

    htop.enable = true;

    jq.enable = true;

    java.enable = true;

    k9s.enable = true;

    lazygit.enable = true;

    less.enable = true;

    man.enable = true;

    nix-index.enable = true;

    pandoc.enable = true;

    ripgrep.enable = true;

    starship.enable = true;

    yt-dlp.enable = false;

    zoxide.enable = true;

    zellij.enable = true;

  };

  services = {

    # Enable the emacs daemon
    emacsDaemon = { enable = true; };

    # Enable the cachix agent
    cachix-agent = {
      enableLaunchdAgent = true;
      name = "nix-community";
      credentialsFile = ./cachix-agent.dhall;
    };

    # Enable shadowing folders
    shadowRepositories = {

      enable = false;

      mountPoints =
        [ "/Volumes/GitHub/HylandSoftware/hxpr" "/Volumes/GitHub/nuxeo/nos" ];

    };

  };

}
