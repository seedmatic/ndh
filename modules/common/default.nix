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
    ./bird-daemon.nix
    ./dnsmasq.nix
    ./qemu.nix
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
      ../home-manager
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

  # zen-browser = {
  #    enable = false;
  #    packages = pkgs.zen-browser-unwrapped;
  #  };

  # environment setup
  environment = {
    variables = {
      XDG_RUNTIME_DIR = "${config.user.home}/.xdg";
    };

    systemPackages = import ./system-packages.nix {
      inherit pkgs inputs config;
    };

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
