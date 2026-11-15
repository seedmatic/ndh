# modules/.common.d

## OVERVIEW
Shared Nix modules consumed by both darwin and nixos hosts. Largest module set (199 files, 33 feature subdirs).

## STRUCTURE
Root feature.nix files (attic-client, cache-trust, nix-settings, sops, ssh-paths, system-packages, ...) plus feature.d/ subdirs for assets/tests.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Nix settings | nix-settings.nix, nixpkgs*.nix |
| Secrets/sops | sops.nix, keys-yaml.nix, sops.d/ |
| SSH paths | ssh-paths.nix, ssh-keys*.nix, ssh-keys.d/ |
| Packages | system-packages*.nix |
| Shell assets | shell.d/ |
| Tests | *.d/tests, pkgs/*.bats |
| Attic cache | attic-client.nix, attic-tokens.d/ |
| Tailnet | tailnet*.nix, manage-tailnet.d/ |
| Host keys | host-key.d/, keys-yaml.d/, keys-reconcile.d/ |
| Operators | ndh-ops.d/, ndh-switch.d/, fleet-switch.d/, ops-queue.d/ |
| Keyring | keyring.d/ |

## CONVENTIONS
- Module signature: { config, lib, options, pkgs, self, worktreePath, ndh, ... }.
- Use ndh.context for catalog/inventory.
- Asset subdirs use .d suffix.
- Guard platform-specific bits with isNixosPlatform.
- Shared scripts use @nixBashTrampoline@ and ndh::logger:command:run.

## ANTI-PATTERNS
- Don't put platform-specific code here; guard with isNixosPlatform.
- Don't duplicate a module in darwin/ or nixos/ if it can live here.
- Don't run operator tools without arming (ndh-ops arm).

## NOTES
- 33 feature subdirs; most are small single-feature modules.
- See child AGENTS.md for keys-yaml.d, keys-reconcile.d, ssh-keys.d, shell.d, sops.d,
  attic-tokens.d, host-key.d, keyring.d, manage-tailnet.d where present.
