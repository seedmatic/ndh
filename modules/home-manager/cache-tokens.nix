{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.programs.cache-tokens;

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
    home.activation.setupCacheTokens = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      builtins.readFile (
        pkgs.replaceVars ./cache-tokens.d/setup-cache-tokens.sh {
          cacheTokensFile = cacheTokensFile;
          yq = "${pkgs.yq-go}/bin/yq";
          sed = "${pkgs.gnused}/bin/sed";
        }
      )
    );
  };
}
