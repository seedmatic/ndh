{
  config,
  lib,
  options,
  pkgs,
  self,
  catalog,
  hostProfile ? null,
  ...
}:
let
  userMapping = catalog.users;
  isNixosPlatform = options ? systemd;
  hostImageMode =
    if hostProfile != null && hostProfile ? nixosImageMode && hostProfile.nixosImageMode != null then
      hostProfile.nixosImageMode
    else
      "full";
  # Bootstrap image mode is a NixOS guest concern. Keep Home Manager enabled on
  # Darwin hosts even when they orchestrate bootstrap guest flows.
  bringupModeInternal = isNixosPlatform && hostImageMode == "bootstrap";
  requestedHomeManagerEnabled =
    if hostProfile != null && hostProfile ? enableHomeManager && hostProfile.enableHomeManager != null then
      hostProfile.enableHomeManager
    else
      true;
  homeManagerEnabled = if bringupModeInternal then false else requestedHomeManagerEnabled;

  cfg = config.profile;
  profile = cfg;
  user = cfg.user;
  userName = user.name;
  userHome = toString cfg.user.home;
  activationLogFile = "${userHome}/.local/state/nix/activation.log";
  hmActivationPackage = lib.attrByPath [
    "home-manager"
    "users"
    userName
    "home"
    "activationPackage"
  ] null config;
  hmUserExists = hmActivationPackage != null;
  loggerBase = ./shell.d/logger.sh;
  loggerScript = pkgs.runCommand "logger.sh" { } ''
        cat > "$out" <<'EOF'
    #!/usr/bin/env bash
    LOGGER_CMD="${config.activation.loggerCmd}"
    source ${loggerBase}
    EOF
  '';
  activationTagHmPost = "common.activationScripts.postActivation.home-manager";
  # Define systemPackages separately
  systemPackages = import ./system-packages.nix {
    inherit pkgs lib;
    # Pass only necessary parts of config, not the entire config
    inherit (config) programs environment;
  };

  postActivationScriptSource = pkgs.replaceVars ./shell.d/post-activation.sh {
    hmActivationPackage = toString hmActivationPackage;
    userName = userName;
    userHome = userHome;
    logger = loggerScript;
    activationTag = activationTagHmPost;
    postActivationLogShowLabel = config.activation.postActivationLogShowLabel;
    postActivationLogShowCmd = config.activation.postActivationLogShowCmd;
    postActivationLogStreamLabel = config.activation.postActivationLogStreamLabel;
    postActivationLogStreamCmd = config.activation.postActivationLogStreamCmd;
  };

  postActivationScript = pkgs.runCommand "hm-post-activation.sh" { } ''
    install -m 0555 ${postActivationScriptSource} "$out"
  '';

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

  options.activation.homeManagerPostActivationScript = lib.mkOption {
    type = lib.types.path;
    readOnly = true;
    description = "Wrapped Home Manager post-activation script produced by common module logic.";
  };

  options.activation.postActivationLogShowLabel = lib.mkOption {
    type = lib.types.str;
    default = "activation logs (recent)";
    description = "Label shown for post-activation recent-log inspection command.";
  };

  options.activation.postActivationLogShowCmd = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = "Platform-provided command for inspecting recent activation logs after post-activation.";
  };

  options.activation.postActivationLogStreamLabel = lib.mkOption {
    type = lib.types.str;
    default = "activation logs (stream)";
    description = "Label shown for post-activation live-log streaming command.";
  };

  options.activation.postActivationLogStreamCmd = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = "Platform-provided command for streaming activation logs after post-activation.";
  };

  imports = [
    ../../profiles/common.nix
    ./cachix-watch-store.nix
    ./sops.nix
    ./primary-user.nix
    ./user.nix
    ./nixpkgs.nix
    ./dns-servers.nix
    ./dnsmasq.nix
    ./lima-host.nix
    ./distributed-builds-option.nix
  ];

  config = {

    activation.loggerScript = loggerScript;
    activation.homeManagerPostActivationScript = postActivationScript;

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
    hm = lib.mkIf homeManagerEnabled (import ../home-manager {
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
        logger = {
          script = loggerScript;
          cmd = config.activation.loggerCmd;
        };
        sshKeysYamlPath = lib.attrByPath [
          "sops"
          "secrets"
          "keys.yaml"
          "path"
        ] (toString ../../modules/home-manager/ssh.d/keys.yaml) config;
      };
    });

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
  }
  // (lib.optionalAttrs homeManagerEnabled {
    # let nix manage home-manager profiles and use global nixpkgs
    home-manager = {
      extraSpecialArgs = {
        inherit self catalog;
        profile = config.profile;
        logger = {
          script = loggerScript;
          cmd = config.activation.loggerCmd;
        };
        sshKeysYamlPath = lib.attrByPath [
          "sops"
          "secrets"
          "keys.yaml"
          "path"
        ] (toString ../../modules/home-manager/ssh.d/keys.yaml) config;
      };
      useGlobalPkgs = true;
      useUserPackages = true;
      verbose = true;
      backupFileExtension = "nix-backup";
    };
  });

}
