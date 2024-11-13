{
  config,
  pkgs,
  ...
}: {
  imports = [
    ./avahi.nix
    ./bat.nix
    ./chromium.nix
    ./dircolors.nix
    ./direnv.nix
    ./dotfiles
    ./emacs.nix
    ./firefox.nix
    ./fzf.nix
    ./git.nix
    ./gh.nix
    ./gpg.nix
    ./java.nix
    ./keychain.nix
    ./kitty.nix
    ./nushell.nix
    ./password-store.nix
    ./shell
    ./ssh.nix
    ./tldr.nix
    ./tmate.nix
    ./tmux.nix
    ./vscode
    ./xdg.nix
  ];

  nixpkgs.config = {
    allowUnfree = true;
  };

  home = {
    stateVersion = "22.05";

    sessionPath = [
      "${config.home.homeDirectory}/.rd/bin"
      "${config.home.homeDirectory}/.local/bin"
    ];

    # Define package definitions for current user environment
    packages = with pkgs; [
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
      krew
      kubectl
      kubectx
      kubernetes-helm
      kustomize
      lazydocker
      luajit
      mmv
      neofetch
      nix
      nixfmt-classic
      nixpkgs-fmt
      nodejs
      pnpm
      parallel
      passExtensions.pass-otp
      passExtensions.pass-audit
      passExtensions.pass-update
      passExtensions.pass-import
      passExtensions.pass-checkup
      passExtensions.pass-genphrase
      poetry
      pre-commit
      ranger
      rclone
      rsync
      shellcheck
      sops
      stylua
      sysdo
      tig
      tree
      treefmt
      trivy
      vfkit
      yarn
      yamllint
      yq-go
      zsh
    ];
  };

  targets.genericLinux.enable = false;

  programs = {
    home-manager = {
      enable = true;
    };

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
  };
}
