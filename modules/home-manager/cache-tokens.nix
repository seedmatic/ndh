{
  config,
  pkgs,
  lib,
  ...
}:

let
  profile = config._module.specialArgs.profile;
  cfg = config.programs.cache-tokens;
  userName = profile.user.name;
  activationLogger = config._module.specialArgs.activationLogger.script;
  activationTag = "home-manager.activationScripts.${userName}.setupCacheTokens";

  stateHome = config.xdg.stateHome;
  cacheTokensFile = "${stateHome}/cache-tokens.yaml";

in
{
  options.programs.cache-tokens = {
    enable = lib.mkEnableOption "cache tokens management";

    tokenFile = lib.mkOption {
      type = lib.types.path;
      default = ./cache.d/tokens.yaml;
      description = "Path to the SOPS-encrypted cache tokens YAML file";
    };
  };

  config = lib.mkIf cfg.enable {
    # Disable the conflicting cachix-agent dhall config that has SOPS parsing issues
    xdg.configFile."cachix/cachix.dhall" = lib.mkForce {
      enable = false;
    };

    home.file."${cacheTokensFile}".source = cfg.tokenFile;

    # Make the cache tokens available to nix and setup cachix config without SOPS issues
    home.activation.setupCacheTokens =
      let
        setupCacheTokensScript = pkgs.replaceVars ./cache-tokens.d/setup-cache-tokens.sh {
          cacheTokensFile = cacheTokensFile;
          yq = "${pkgs.yq-go}/bin/yq";
          sed = "${pkgs.gnused}/bin/sed";
          activationLogger = activationLogger;
          activationTag = activationTag;
        };
      in
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${pkgs.bash}/bin/bash ${setupCacheTokensScript}
      '';
  };
}
