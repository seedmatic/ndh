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

    flakehub = {
      substituter = "https://cache.flakehub.com";
      publicKey = "cache.flakehub.com-1:t7S7JjLyIJJLv0a0BqXdFnJvr4P8pAB2Z9xN2lYZXvY=";
    };

    flox = {
      substituter = "https://cache.flox.dev";
      publicKey = "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs=";
    };

    aseippFastly = {
      substituter = "https://aseipp-nix-cache.freetls.fastly.net";
    };

    tunaMirror = {
      substituter = "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store";
    };
  };
}
