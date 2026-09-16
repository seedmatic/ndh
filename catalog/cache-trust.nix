{
  caches = {
    nixos = {
      substituter = "https://cache.nixos.org";
      publicKey = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
    };

    nxmatic = {
      substituter = "https://nxmatic.cachix.org";
      publicKey = "nxmatic.cachix.org-1:huMghYiwDpPa1PMXHXK4G1Dp4QOZjgsNqxcjf/AjuJ0=";
    };

    flox = {
      substituter = "https://cache.flox.dev";
      publicKey = "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs=";
    };

    # Fleet-owned signing keypairs, grouped under `cachix` to distinguish
    # from external third-party caches above. Privates live encrypted at
    # catalog/cache-trust.yaml under caches.cachix.<name>; publics here
    # drive trusted-public-keys and the signing-key deploy wiring in
    # modules/.common.d/nix-signing.nix.
    cachix = {
      # Single shared signing key for the nix-darwin-home fleet. Lets any
      # host `nix copy` locally-built paths peer-to-peer over ssh-ng —
      # they all trust each other's signatures. No substituter — the key
      # signs intra-fleet traffic, not a published cache.
      "io-nxmatic-nix-darwin-home" = {
        publicKey = "io-nxmatic-nix-darwin-home:U/at4v0hCbZhn3u7uvQhQo+lzq5ZobOJyn3Be3txbqg=";
      };
    };

    aseippFastly = {
      substituter = "https://aseipp-nix-cache.freetls.fastly.net";
    };

    tunaMirror = {
      substituter = "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store";
    };
  };
}
