{
  self,
  inputs,
  config,
  pkgs,
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
      nix-index

      # standard toolset
      coreutils-full
      findutils
      diffutils
      ripgrep
      curl
      wget
      git
      remake

      # yaml
      yq-go
      yamllint

      # shells
      bash
      fish
      zsh

      # shell debugging
      shellcheck
      bashdb

      # terminals
      kitty
      tmuxinator
      tmux
      reattach-to-user-namespace
      # byobu (broken see above)
      # disabled byobu, newt not installable on darwin, should use brew instead

      # helpful shell stuff
      broot
      fd
      bat
      fzf
      ripgrep

      # git
      git
      tig

      # github cli
      actionlint
      gh

      # editors
      neovim
      emacs-nox

      # java
      jdk19
      # maven (use mvnd, mvnw wrapper instead)

      # ide
      vscode

      # web browsing
      #      brave (glibc)
      w3m
      html2text

      # social
      #      keybase ( AudioFormat.h:161:8: error: redefinition of 'AudioFormatListItem')
      slack
      zoom-us

      # shell
      powerline-go
      zoxide

      # document viewer
      zathura

      # knowledge base (need glibc on darwin)
      # obsidian
      # zotero

      # virtual env manager for coding
      direnv
      lorri

      # container runtimes
      lima
      colima
      qemu
      docker-client

      # keystore crypto
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

      unstable.sops
    ];

    etc = {
      home-manager.source = "${inputs.home-manager}";
      nixpkgs.source = "${inputs.nixpkgs}";
      stable.source = "${inputs.stable}";
    };

    # list of acceptable shells in /etc/shells
    shells = with pkgs; [bash zsh fish];
  };

  fonts = {
    fontDir.enable = true;
    fonts = with pkgs; [powerline-fonts];
  };
}
