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
    home.activation.setupCacheTokens = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            # Extract cache configuration from SOPS-encrypted YAML
            if [[ -f "${cacheTokensFile}" ]]; then
              # Parse YAML and extract nxmatic token
              NXMATIC_TOKEN=$(${pkgs.yq-go}/bin/yq '.cache.nxmatic.token' "${cacheTokensFile}")
              NXMATIC_URL=$(${pkgs.yq-go}/bin/yq '.cache.nxmatic.url' "${cacheTokensFile}")
              
              if [[ -n "$NXMATIC_TOKEN" && "$NXMATIC_TOKEN" != "null" ]]; then
                # Setup cachix configuration in the expected format
                mkdir -p ~/.config/cachix
                cat > ~/.config/cachix/cachix.dhall << 'EOF'
      { authToken = "REPLACE_TOKEN_HERE"
      , hostname = "https://cachix.org" 
      , binaryCaches = [] : List { name : Text, secretKey : Text }
      }
      EOF
                # Escape chars that sed 's///' treats specially (/, \\ and &)
                ESCAPED_TOKEN=$(printf '%s' "$NXMATIC_TOKEN" | ${pkgs.gnused}/bin/sed -e 's/[\\/&]/\\&/g')
                ${pkgs.gnused}/bin/sed -i "s/REPLACE_TOKEN_HERE/$ESCAPED_TOKEN/g" ~/.config/cachix/cachix.dhall
                echo "✅ Cachix configuration created successfully"
              else
                echo "❌ Failed to extract nxmatic token from cache tokens file"
              fi
            else
              echo "❌ Cache tokens file not found: ${cacheTokensFile}"
            fi
    '';
  };
}
