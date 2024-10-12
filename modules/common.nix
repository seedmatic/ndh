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
    ./dnsmasq.nix
    ./bird-daemon.nix
  ];

  nixpkgs.overlays =
    builtins.attrValues self.overlays
    ++ [
      (final: prev: {
        bird = prev.bird.overrideAttrs (oldAttrs: {
          version = "2.15.1";
          src = final.fetchFromGitHub {
            owner = "nxmatic";
            repo = "bird";
            rev = "hotfix/v${oldAttrs.version}-nix-darwin";
            sha256 = "sha256-opSYMOTuOXlFfz6NPWIzxhNSp2sk2CyryYbuo1wr46s=";
          };

          sourceRoot = "source/bird-hotfix-v${oldAttrs.version}-nix-darwin";

          buildInputs =
            (oldAttrs.buildInputs or [])
            ++ final.lib.optionals final.stdenv.isDarwin [
              final.darwin.apple_sdk.frameworks.CoreFoundation
              final.darwin.apple_sdk.frameworks.Security
            ];

          nativeBuildInputs =
            (oldAttrs.nativeBuildInputs or [])
            ++ [
              final.autoconf
              final.automake
              final.libtool
              final.pkg-config
            ];

          configureFlags =
            (oldAttrs.configureFlags or [])
            ++ [
              "--with-sysconfig=bsd"
            ];

          preConfigure = ''
            ${oldAttrs.preConfigure or ""}
            echo "Running autoreconf..."
            autoreconf -vfi
          '';

          configurePhase = ''
            runHook preConfigure

            echo "Running configure with --with-sysconfig=bsd"
            ./configure \
              --prefix=$out \
              --localstatedir=/var \
              --runstatedir=/run/bird \
              --with-sysconfig=bsd \
              ''${configureFlags:+$configureFlags}

            runHook postConfigure
          '';
        });
      })
    ];

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
      clang_19
      coreutils-full
      cmake
      curl
      diffutils
      findutils
      getopt
      git
      git-town
      gitAndTools.gitflow
      gnused
      libevent
      pstree
      remake
      wget
      pcre2

      # system build
      autoconf
      automake
      bison
      libtool

      # yaml
      yq-go
      yamllint

      # shells
      #bashInteractive
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
      kitty-themes
      terminal-notifier
      tmuxinator
      tmux
      tmate # tmux clone for GHA
      tmate-ssh-server
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

      # python
      python3Full
      python3Packages.dnslib

      # ide
      vscode
      openvscode-server

      # web browsing
      #brave (glibc)
      #chromium (rosetta)
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
      realvnc-vnc-viewer # vnc viewer

      # networking
      dbus
      avahi
      bird
      nmap
      tshark
      dnsmasq
      ipcalc

      # nodejs
      sauce-connect

      # android
      android-tools

      # container runtimes
      buildkit
      docker-client
      docker-credential-gcr
      docker-credential-helpers
      colima
      lima
      qemu
      podman
      podman-compose

      # crypto
      gnupg
      #pinentry
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
    shells = with pkgs; [bash zsh fish];
  };

  services.tailscale = {
    enable = true;
    #logDir = config.logDir or null; # Use the value of the logDir option, or null if it is not set
  };

  services.bird = {
    enable = true;

    interface = "bridge100";
    protocols = [
      {
        name = "kernel";
        text = ''
          protocol kernel kernel4 {
            ipv4 {
              import all;
              export all;
            };
            learn;
            debug all;
          }
        '';
      }
      {
        name = "rip";
        text = ''
          protocol rip rip4 {
            ipv4 {
              import all;
              export none;
            };
            interface "bridge100" {
              version 2;
            };
            debug all;
          }
        '';
      }
      # ... other protocols ...
    ];
  };

  fonts = {
    packages = with pkgs; [powerline-fonts];
  };
}
