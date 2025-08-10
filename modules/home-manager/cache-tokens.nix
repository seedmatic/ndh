{ config, pkgs, lib, ... }:

let
  cfg = config.programs.cache-tokens;
  
  stateHome = config.xdg.stateHome;
  cacheTokensFile = "${stateHome}/cache-tokens.yaml";
  
in {
  options.programs.cache-tokens = {
    enable = lib.mkEnableOption "cache tokens management";
    
    tokenFile = lib.mkOption {
      type = lib.types.path;
      default = ./cache.d/tokens.yaml;
      description = "Path to the SOPS-encrypted cache tokens YAML file";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file."${cacheTokensFile}".source = cfg.tokenFile;
    
    # Make the cache tokens available to nix
    home.activation.setupCacheTokens = lib.hm.dag.entryAfter ["writeBoundary"] ''
      # Extract cache configuration from SOPS-encrypted YAML
      if [[ -f "${cacheTokensFile}" ]]; then
        # Parse YAML and extract nxmatic token
        NXMATIC_TOKEN=$(${pkgs.yq-go}/bin/yq '.cache.nxmatic.token' "${cacheTokensFile}")
        NXMATIC_URL=$(${pkgs.yq-go}/bin/yq '.cache.nxmatic.url' "${cacheTokensFile}")
        
        # Setup cachix configuration
        mkdir -p ~/.config/cachix
        cat > ~/.config/cachix/cachix.dhall << EOF
{ name = "nxmatic"
, secretKey = None Text
, authToken = "$NXMATIC_TOKEN"
, publicKey = "nxmatic.cachix.org-1:oWogvXdam3gTxKzPZCDqq8khybQpqRdNpQQrKG3r4xM="
, api = "https://cachix.org"
, compressionMethod = "zstd"
, compressionLevel = +3
}
EOF
        
        # Setup .netrc for cachix authentication
        if [[ ! -f ~/.netrc ]]; then
          touch ~/.netrc
          chmod 600 ~/.netrc
        fi
        
        # Remove any existing cachix.org entry and add new one
        ${pkgs.gnugrep}/bin/grep -v "machine cachix.org" ~/.netrc > ~/.netrc.tmp || true
        ${pkgs.gnugrep}/bin/grep -v "login token" ~/.netrc.tmp > ~/.netrc || true
        ${pkgs.gnugrep}/bin/grep -v "password.*eyJ" ~/.netrc > ~/.netrc.tmp || true
        mv ~/.netrc.tmp ~/.netrc 2>/dev/null || true
        
        cat >> ~/.netrc << EOF

machine cachix.org
login token
password $NXMATIC_TOKEN
EOF
        chmod 600 ~/.netrc
      fi
    '';
  };
}
