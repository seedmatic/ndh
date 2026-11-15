# modules

## OVERVIEW
All Nix configuration modules: shared (.common.d), platform-specific (darwin, nixos), home-manager, hardware. Consumed by hosts via flake.

## STRUCTURE
```
modules/
├── .common.d/    # shared modules + assets (199 files, 33 subdirs)
├── darwin/       # macOS-specific (130 files, 27 subdirs)
├── nixos/        # NixOS-specific (143 files, 12 subdirs)
├── home-manager/ # HM modules (133 files, 14 subdirs)
└── hardware/     # hardware profiles (1 file)
```

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Shared logic | .common.d/ |
| macOS config | darwin/ |
| Linux config | nixos/ |
| User env | home-manager/ |
| Hardware profile | hardware/phil.nix |
| Module wiring | hosts/<name>/*.nix imports modules/ |

## CONVENTIONS
- Each feature: feature.nix + optional feature.d/ assets/tests.
- .common.d modules guarded by isNixosPlatform flag.
- Home Manager wired via mkNdhHomeManagerSpecialArgs.
- Profile roles: bringup / system / user; HM disabled in bringup.
- Module signature: { config, lib, options, pkgs, self, worktreePath, ndh, ... }.

## ANTI-PATTERNS
- Don't duplicate between .common.d and platform dirs; prefer .common.d.
- Don't put platform-specific code in .common.d without isNixosPlatform guard.
- Don't put darwin config in nixos/ or vice versa.

## NOTES
- modules/hardware/ has a single profile; parent covers it.
- Hosts import modules/ + profile; secrets via sops.
- Tests run via `nix flake check`.
- New modules should follow feature.nix + feature.d/ layout.
