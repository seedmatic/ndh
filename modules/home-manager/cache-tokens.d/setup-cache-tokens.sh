source @activationLogger@

main() {
  set -euo pipefail

  # Extract cache configuration from SOPS-encrypted YAML
  if [[ -f "@cacheTokensFile@" ]]; then
    NXMATIC_TOKEN=$(@yq@ '.cache.nxmatic.token' "@cacheTokensFile@")
    NXMATIC_URL=$(@yq@ '.cache.nxmatic.url' "@cacheTokensFile@")

    if [[ -n "$NXMATIC_TOKEN" && "$NXMATIC_TOKEN" != "null" ]]; then
      mkdir -p ~/.config/cachix
      cat > ~/.config/cachix/cachix.dhall << 'EOF'
{ authToken = "REPLACE_TOKEN_HERE"
, hostname = "https://cachix.org"
, binaryCaches = [] : List { name : Text, secretKey : Text }
}
EOF
      ESCAPED_TOKEN=$(printf '%s' "$NXMATIC_TOKEN" | @sed@ -e 's/[\\/&]/\\&/g')
      @sed@ -i "s/REPLACE_TOKEN_HERE/$ESCAPED_TOKEN/g" ~/.config/cachix/cachix.dhall
      echo "Cachix configuration created successfully"
    else
      echo "Failed to extract nxmatic token from cache tokens file"
    fi
  else
    echo "Cache tokens file not found: @cacheTokensFile@"
  fi
}

activation_run "@activationTag@" main "$@"
