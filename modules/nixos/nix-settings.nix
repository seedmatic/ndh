# Nix daemon configuration shared across NixOS systems.
# Configures experimental features, substituters, trusted users, and optimization.
{ config, lib, ... }:
let
  ndhContext = config.ndh.context or { };
  catalog = ndhContext.catalog or { };
  cacheCatalog = catalog.caches or { };

  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;
  rootUserName = "root";

  # Safe attribute access with fallbacks for missing cache entries
  hasAseippFastly = cacheCatalog ? aseippFastly && cacheCatalog.aseippFastly ? substituter;
  hasNxmatic = cacheCatalog ? nxmatic && cacheCatalog.nxmatic ? substituter;
  hasNixos = cacheCatalog ? nixos && cacheCatalog.nixos ? publicKey;
in
{
  nix.settings = {
    # experimental-features declared in modules/.common.d/nix-settings.nix
    # (baseline for both NixOS and nix-darwin); this file adds the NixOS-
    # specific substituters, trusted-users, and store optimisation policy.
    auto-optimise-store = false; # Manual optimise recommended; improves build latency during development.
    trusted-users = [
      cfgUserName
      rootUserName
      "builder" # remote builder user (nerd-nixos Lima VM)
    ];
    sandbox = false;
    # Keep sandbox disabled for this profile set; do not force host-local
    # device paths (e.g. /dev/kvm) into evaluated settings, as that breaks
    # evaluation on non-KVM bringup/runtime hosts.

    # Cache settings with Fastly CDN for faster downloads
    # Using 'substituters' (not 'extra-substituters') to control order
    # Alternative caches (uncomment one to use):
    # - "${cacheCatalog.nixos.substituter}"                                  # Official NixOS cache (default)
    # - "${cacheCatalog.aseippFastly.substituter}"              # Fastly Cache v2 (recommended, faster) - currently active
    # - "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"  # Tsinghua University (China)
    # - "https://mirrors.ustc.edu.cn/nix-channels/store"           # USTC (China)
    # - "https://mirrors.bfsu.edu.cn/nix-channels/store"           # BFSU (China)
    substituters = lib.filter (s: s != "") [
      (if hasAseippFastly then cacheCatalog.aseippFastly.substituter else "")
      (if hasNxmatic then cacheCatalog.nxmatic.substituter else "")
    ];
    trusted-public-keys = lib.filter (k: k != "") [
      (if hasNixos then cacheCatalog.nixos.publicKey else "")
      (if hasNxmatic then cacheCatalog.nxmatic.publicKey else "")
    ];
    # NOTE (@codebase): Rollback instructions:
    #   - Remove "ca-derivations" from experimental-features.
    #   - Set auto-optimise-store = true to restore inline dedup.
    # Validation:
    #   - Check a new build's store path naming stability when spec changes trivially.
    #   - Run `nix-store --optimise --dry-run` after several builds to assess dedup benefit.
  };

  nix.extraOptions = ''
    !include /etc/nix/nix.custom.conf
  '';
}
