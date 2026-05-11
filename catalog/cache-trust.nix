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
      publicKeys = [
        "cache.flakehub.com-1:t7S7JjLyIJJLv0a0BqXdFnJvr4P8pAB2Z9xN2lYZXvY="
        "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
        "cache.flakehub.com-4:Asi8qIv291s0aYLyH6IOnr5Kf6+OF14WVjkE6t3xMio="
        "cache.flakehub.com-5:zB96CRlL7tiPtzA9/WKyPkp3A2vqxqgdgyTVNGShPDU="
        "cache.flakehub.com-6:W4EGFwAGgBj3he7c5fNh9NkOXw0PUVaxygCVKeuvaqU="
        "cache.flakehub.com-7:mvxJ2DZVHn/kRxlIaxYNMuDG1OvMckZu32um1TadOR8="
        "cache.flakehub.com-8:moO+OVS0mnTjBTcOUh2kYLQEd59ExzyoW1QgQ8XAARQ="
        "cache.flakehub.com-9:wChaSeTI6TeCuV/Sg2513ZIM9i0qJaYsF+lZCXg0J6o="
        "cache.flakehub.com-10:2GqeNlIp6AKp4EF2MVbE1kBOp9iBSyo0UPR9KoR0o1Y="
      ];
    };

    flox = {
      substituter = "https://cache.flox.dev";
      publicKey = "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs=";
    };

    # Local signing key used by bioskop's nix-daemon
    # (secret-key-files = /etc/nix/bioskop-cache.key, wired at
    # hosts/bioskop/nixos.nix). Every other host that does `nix copy
    # --from ssh-ng://…@bioskop.*` must trust this pub to accept the
    # locally-built paths (storage.conf, nixos-generation, etc.) that
    # carry no cache.nixos.org signature. No substituter — bioskop isn't
    # published as a cache; it's peer-to-peer over ssh-ng.
    bioskop = {
      publicKey = "bioskop-cache:H6oZXzgzujE4+saXVe6LDfzBRUUVCgPYYTFLoxK7IuE=";
    };

    aseippFastly = {
      substituter = "https://aseipp-nix-cache.freetls.fastly.net";
    };

    tunaMirror = {
      substituter = "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store";
    };
  };
}
