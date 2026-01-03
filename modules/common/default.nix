{
  config,
  lib,
  pkgs,
  self,
  catalog,
  ...
}:
let
  userMapping = catalog.users;

  cfg = config.profile;
  profile = cfg;
  user = cfg.user;
  userName = user.name;
  userHome = "${if pkgs.stdenvNoCC.isDarwin then "/Users" else "/home"}/${userName}";
  hmActivationPackage = lib.attrByPath [
    "home-manager"
    "users"
    userName
    "activationPackage"
  ] null config;
  hmUserExists = hmActivationPackage != null;
  activationLoggerBase = ./default.d/activation-logger.sh;
  activationLoggerScript = pkgs.writeText "activation-logger.sh" ''
    #!/usr/bin/env bash
    LOGGER_CMD="${config.activation.loggerCmd}"
    source ${activationLoggerBase}
  '';
  activationTagHmPost = "common.activationScripts.postActivation.home-manager";

  # Define systemPackages separately
  systemPackages = import ./system-packages.nix {
    inherit pkgs lib;
    # Pass only necessary parts of config, not the entire config
    inherit (config) programs environment;
  };

  postActivationScript = pkgs.replaceVars ./default.d/post-activation.sh {
    hmActivationPackage = toString hmActivationPackage;
    userName = userName;
    userHome = userHome;
    activationLogger = activationLoggerScript;
    activationTag = activationTagHmPost;
  };

in
{

  options.activation.loggerCmd = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = "Command line (with %TAG% placeholder) to route activation logs";
  };

  options.activation.loggerScript = lib.mkOption {
    type = lib.types.path;
    readOnly = true;
    description = "Wrapped activation logger script that exports LOGGER_CMD";
  };

  imports = [
    ../../profiles/common.nix
    ./primary-user.nix
    ./user.nix
    ./nixpkgs.nix
    ./dns-servers.nix
    ./dnsmasq.nix
    ./lima-host.nix
    ./distributed-builds-option.nix
  ];

  config = {

    activation.loggerScript = activationLoggerScript;

    programs = {

      bash = {
        completion.enable = true;
      };

      zsh = {
        enable = true;
        enableCompletion = true;
        enableBashCompletion = true;
      };
    };

    # bootstrap home manager using system config
    hm = import ../home-manager {
      inherit
        config
        pkgs
        lib
        user
        self
        profile
        ;

      # Provide specialArgs explicitly for direct imports
      specialArgs = {
        inherit profile catalog;
        activationLogger = {
          script = activationLoggerScript;
          cmd = config.activation.loggerCmd;
        };
      };
    };

    # Run home-manager after all other activation steps so user files see final system state
    system.activationScripts.postActivation.text = lib.mkOrder 2000 (
      lib.optionalString (pkgs.stdenvNoCC.isDarwin && hmUserExists) ''
        ${postActivationScript}
      ''
    );

    # let nix manage home-manager profiles and use global nixpkgs
    home-manager = {
      extraSpecialArgs = {
        inherit self catalog;
        profile = config.profile;
        activationLogger = {
          script = activationLoggerScript;
          cmd = config.activation.loggerCmd;
        };
      };
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

      inherit systemPackages;

      variables = {
        XDG_RUNTIME_DIR = "${userHome}/.xdg";
      };

      # list of acceptable shells in /etc/shells
      shells = with pkgs; [
        bash
        zsh
        fish
      ];
    };

    services.tailscale = {
      enable = true;
    };

    fonts = {
      packages = with pkgs; [ powerline-fonts ];
    };

    limaHost = {
      guestName = "nixos";
    };
  };

}
