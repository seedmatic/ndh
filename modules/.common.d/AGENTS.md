# modules/.common.d

## OVERVIEW
Shared Nix modules consumed by both darwin and nixos hosts. Largest module set (199 files, 33 feature subdirs).

## STRUCTURE
Root feature.nix files (attic-client, cache-trust, nix-settings, sops, ssh-paths, system-packages, ...) plus feature.d/ subdirs for assets/tests.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Nix settings | nix-settings.nix, nixpkgs*.nix |
| Secrets/sops | sops.nix, keys-yaml.nix |
| SSH paths | ssh-paths.nix, ssh-keys*.nix |
| Packages | system-packages*.nix |
| Shell assets | shell.d/ |
| Tests | *.d/tests, pkgs/*.bats |
| Attic cache | attic-client.nix, attic-tokens.d/ |
| Tailnet | tailnet*.nix, manage-tailnet.d/ |

## CONVENTIONS
- Module signature: { config, lib, options, pkgs, self, worktreePath, ndh, ... }.
- Use ndh.context for catalog/inventory.
- Asset subdirs use .d suffix.
- Guard platform-specific bits with isNixosPlatform.

## ANTI-PATTERNS
- Don't put platform-specific code here; guard with isNixosPlatform.
- Don't duplicate a module in darwin/ or nixos/ if it can live here.

## NOTES
- 33 feature subdirs; most are small single-feature modules.
