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

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    enableBashCompletion = true;
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
      ./home-manager/1password.nix
    ];
  };

  # let nix manage home-manager profiles and use global nixpkgs
  home-manager = {
    extraSpecialArgs = {inherit self inputs;};
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "backup";
  };

  # environment setup
  environment = {
    systemPackages = with pkgs; [
      # home manager
      home-manager

      # shells
      bash
      fish
      zsh

      # terminals
      kitty
      tmuxinator
      tmux
      # byobu (broken see above)

      # git
      tig

      # disabled byobu, newt not installable on darwin, should use brew instead

      # editors
      neovim
      emacs-nox

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

      # virtual env manager for coding
      asdf-vm

      # keystore crypto
      gnupg
      passExtensions.pass-audit
      passExtensions.pass-checkup
      passExtensions.pass-otp
      #passExtensions.update
      pass-git-helper
      sops

      # helpful shell stuff
      broot
      fd
      bat
      fzf
      ripgrep
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
