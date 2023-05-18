{
  config,
  pkgs,
  ...
}: {
  imports = [
    ./bat.nix
    ./dircolors.nix
    ./direnv.nix
    ./dotfiles
    ./emacs.nix
    ./fzf.nix
    ./git.nix
    ./gh.nix
    ./keychain.nix
    ./kitty.nix
    ./nvim
    ./nushell.nix
    ./password-store.nix
    ./shell
    ./ssh.nix
    ./tldr.nix
    ./tmux.nix
    ./vscode
  ];

  nixpkgs.config = {
    allowUnfree = true;
  };

  home = {
    # This value determines the Home Manager release that your
    # configuration is compatible with. This helps avoid breakage
    # when a new Home Manager release introduces backwards
    # incompatible changes.
    #
    # You can update Home Manager without changing this value. See
    # the Home Manager release notes for a list of state version
    # changes in each release.
    stateVersion = "22.05";

    sessionVariables = {
      GPG_TTY = "/dev/ttys000";
      EDITOR = "emacs";
      VISUAL = "emacs";
      CLICOLOR = 1;
      LSCOLORS = "ExFxBxDxCxegedabagacad";
      KAGGLE_CONFIG_DIR = "${config.xdg.configHome}/kaggle";
      NODE_PATH = "${NODE_GLOBAL}/lib";
      HOMEBREW_NO_AUTO_UPDATE = 1;
      XDG_RUNTIME_DIR  = "$HOME/.xdg";
      XDG_BIN_HOME    = "$HOME/.local/bin";
      ZDOTDIR         = "${config.xdg.configHome}/zsh";
    };

    sessionPath = [
      "${config.home.homeDirectory}/.rd/bin"
      "${config.home.homeDirectory}/.local/bin"
    ];

    # define package definitions for current user environment
    packages = with pkgs; [
      awscli2
      # age
      alejandra
      cachix
      cb
      cirrus-cli
      comma
      coreutils-full
      curl
      diffutils
      fd
      ffmpeg
      findutils
      flyctl
      gawk
      gh
      gnugrep
      gnupg
      gnused
      (
        google-cloud-sdk.withExtraComponents(
          [ google-cloud-sdk.components.gke-gcloud-auth-plugin ]
        )
      )
      helm-docs
      httpie
      hurl
      unstable.jdk11
      krew
      kubectl
      kubectx
      kubernetes-helm
      kustomize
      lazydocker
      luajit
      mmv
      ncdu
      neofetch
      nix
      nixfmt
      nixpkgs-fmt
      nodejs-18_x
      parallel
      passExtensions.pass-otp
      #passExtensions.pass-tomb incompatible with darwin
      passExtensions.pass-audit
      passExtensions.pass-update
      passExtensions.pass-import
      passExtensions.pass-checkup
      passExtensions.pass-genphrase
      poetry
      pre-commit
      # python with default packages
      (python3.withPackages
        (ps:
          with ps; [
            numpy
            scipy
            matplotlib
            networkx
          ]))
      ranger
      rclone
      rsync
      (ruby.withPackages (ps: with ps; [rufo solargraph]))
      shellcheck
      sops
      stylua
      sysdo
      terraform
      tig
      tree
      treefmt
      trivy
      vagrant
      yarn
      yamllint
      unstable.yq-go
    ];
  };

  #targets.genericLinux.enable = true;

  programs = {
    home-manager = {
      enable = true;
    };
    dircolors.enable = true;
    go.enable = true;
    gpg.enable = true;
    password-store.enable = true;
    git.enable = true;
    htop.enable = true;
    jq.enable = true;
    java = {
      enable = true;
      package = pkgs.jdk17;
    };
    k9s.enable = true;
    lazygit.enable = true;
    less.enable = true;
    man.enable = true;
    nix-index.enable = true;
    pandoc.enable = true;
    ripgrep.enable = true;
    starship.enable = true;
    yt-dlp.enable = true;
    zathura.enable = true;
    zoxide.enable = true;
  };

}
