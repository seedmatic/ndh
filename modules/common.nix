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

    #
    # dircolors.enable = true;
    # git.enable = true;
    # go.enable = true;
    # htop.enable = true;
    # jq.enable = true;
    # yq.enable = true;
    # less.enable = true;
    # man.enable = true;
    # nix-index.enable = true;
    # pandoc.enable = true;
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
      #./home-manager/1password.nix
    ];
  };

  # let nix manage home-manager profiles and use global nixpkgs
  home-manager = {
    extraSpecialArgs = {inherit self inputs;};
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "nix-backup";
  };

  # environment setup
  environment = {
    systemPackages = with pkgs; [
      # home manager
      home-manager

      # standard toolset
      coreutils-full
      findutils
      diffutils
      ripgrep
      curl
      wget
      git
      gh
      jq
      yq
      remake

      # shells
      bash
      fish
      zsh

      # terminals
      kitty
      tmuxinator
      tmux
      # byobu (broken see above)
      # disabled byobu, newt not installable on darwin, should use brew instead

      # helpful shell stuff
      broot
      fd
      bat
      fzf
      ripgrep

      # git
      tig

      # editors
      neovim
      emacs-nox

      # virtual env manager for coding
      asdf-vm
      direnv

      # keystore crypto
      gnupg
      passExtensions.pass-audit
      passExtensions.pass-checkup
      passExtensions.pass-otp
      #passExtensions.update
      pass-git-helper
      sops
      pinentry
#     pinentry-curses
#     pinentry_mac
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
