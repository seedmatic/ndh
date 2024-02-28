{
  self,
  inputs,
  config,
  pkgs,
  system,
  ...
}: {
  imports = [
    ./primaryUser.nix
    ./nixpkgs.nix
  ];

  nixpkgs.overlays = builtins.attrValues self.overlays;

  programs = {
    zsh = {
      enable = true;
      enableCompletion = true;
      enableBashCompletion = true;
    };
  };

  user = {
    description = "Stephane Lacoin";
    home = "${
      if pkgs.stdenvNoCC.isDarwin
      then "/Users"
      else "/home"
    }/${config.user.name}";
    shell = pkgs.zsh;
  };

  # bootstrap home manager using system config
  hm = {
    imports = [
      ./home-manager
    ];
  };

  # let nix manage home-manager profiles and use global nixpkgs
  home-manager = {
    extraSpecialArgs = {inherit self inputs;};
    useGlobalPkgs = true;
    useUserPackages = true;
    verbose = true;
    backupFileExtension = "nix-backup";
  };

  # environment setup
  environment = {
    variables = {
      XDG_RUNTIME_DIR = "${config.user.home}/.xdg";
    };

    systemPackages = with pkgs; [
      # nix
      home-manager
      #      nix-du
      #      nix-index
      #      nix-tree
      graphviz

      # standard toolset
      coreutils-full
      curl
      diffutils
      findutils
      getopt
      git
      git-town
      gitAndTools.gitflow
      gnused
      pstree
      remake
      wget

      # yaml
      yq-go
      yamllint

      # shells
      bashInteractive
      fish
      zsh

      # helpful shell stuff
      broot
      #fd
      bat
      fzf
      ripgrep

      # shell debugging
      shellcheck
      bashdb

      # terminals
      kitty
      tmuxinator
      tmux
      reattach-to-user-namespace
      zellij # replace byobu (in evaluation)

      # git
      git
      git-workspace
      tig

      # github cli
      actionlint
      gh

      # editors
      neovim
      emacs-nox

      # java
      jdk
      maven
      maven-mvnd-m39
      gradle

      # ide
      vscode
      openvscode-server
      rnix-lsp

      # web browsing
      #      brave (glibc)
      #chromium
      html2text
      #firefox
      w3m

      # social (see brew cask)
      #kbfs
      #keybase
      #keybase-gui

      slack
      zoom-us

      # shell
      powerline-go
      zoxide

      # document viewer
      # zathura

      # knowledge base (need glibc on darwin)
      # obsidian
      # zotero

      # virtual env manager for coding
      direnv
      #lorri

      # macos
      raycast # launcher
      syncthing # volumes synch

      # networking
      nmap
      tshark

      # android
      android-tools

      # container runtimes
      docker-client
      colima
      lima
      qemu
      podman
      podman-compose

      # crypto
      gnupg
      pinentry
      #     pinentry-curses
      #     pinentry_mac

      oath-toolkit

      pass
      passExtensions.pass-audit
      passExtensions.pass-checkup
      passExtensions.pass-otp
      #passExtensions.update
      pass-git-helper

      sops
    ];

    etc = {
      home-manager.source = "${inputs.home-manager}";
      nixpkgs.source = "${inputs.nixpkgs}";
    };

    # list of acceptable shells in /etc/shells
    shells = with pkgs; [bashInteractive zsh fish];
  };

  services.tailscale = {
    enable = true;
    #logDir = config.logDir or null; # Use the value of the logDir option, or null if it is not set
  };

  fonts = {
    fontDir.enable = true;
    fonts = with pkgs; [powerline-fonts];
  };
}
