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

    # ⚠️ An entry here with a `substituter` is ACTIVE on every host — the module walks this set and
    # appends each one to `extra-substituters` (see the emission contract at the top of
    # modules/.common.d/cache-trust.nix). There is no "documented but inactive" shape, so do NOT
    # park a mirror here for later: a regional mirror was, and every host then queried it.
    #
    # What that cost, measured 2026-09-25 from France: a narinfo round-trip to
    # mirrors.tuna.tsinghua.edu.cn took 1.00 s against 0.20 s for cache.nixos.org (0.52 s in the
    # connect alone). And it was never able to HELP: cache.nixos.org is already first in
    # `substituters`, so the mirror could only ever answer a 404 — and nix walks substituters in
    # order until one has the path, so every locally-built path (i.e. all of ours) paid the full
    # round including that 404. To use a regional mirror while travelling, pass
    # `--option extra-substituters …` for that invocation instead.
  };
}
