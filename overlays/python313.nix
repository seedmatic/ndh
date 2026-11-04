inputs: final: prev: {
  # a2a-sdk: litellm (claude/providers.nix) pulls a2a-sdk via its proxy extras.
  # a2a-sdk 0.3.26 is not cached on aarch64-darwin 26.05, so it builds from
  # source and its checkPhase fails: two e2e tests in
  # tests/e2e/push_notifications/ error with
  #   AttributeError: Can't get local object 'FastAPI.setup.<locals>.openapi'
  # — a FastAPI-internals incompatibility (821 pass, 2 error), not a real
  # regression. Disable checkPhase. Overriding the python313 set here is cheap:
  # verified via `darwin-rebuild build --dry-run` that only a2a-sdk and its
  # reverse-dep litellm rebuild (the fixed-point override does NOT mass-rebuild
  # the set on 26.05) — and litellm already builds from source anyway (its
  # streaming-firsttoken patch in claude/providers.nix busts its cache).
  #
  # Removal: drop once nixpkgs marks the e2e tests broken on darwin / bumps
  # a2a-sdk to a FastAPI-compatible release, or once a2a-sdk is cached.
  python313 = prev.python313.override {
    packageOverrides = pyfinal: pyprev: {
      a2a-sdk = pyprev.a2a-sdk.overridePythonAttrs (_: {
        doCheck = false;
      });
    };
  };
}
