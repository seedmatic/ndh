# PROJECT KNOWLEDGE BASE

**Generated:** 2026-11-15
**Branch:** docs/init-deep-refresh
**Commit:** afeeb5ae

## OVERVIEW
NixOS/nix-darwin fleet configuration ("seedmatic"/ndh). Declarative system + home-manager configs for hosts bioskop (macOS siege + hypervisor), nikopol (roaming laptop), nerd-nixos, and bringup images. Modular Nix modules with bash/bats tests.

## STRUCTURE
```
./
├── modules/        # .common.d (shared), darwin, nixos, home-manager, hardware
├── hosts/          # per-host definitions (bioskop, nikopol, nerd-nixos)
├── docs/           # AsciiDoc specs/runbooks (AsciiDoc only)
├── catalog/        # config catalog (nix + yaml + trust statements)
├── packages/       # Go helpers
├── pkgs/           # nix package defs + bats tests
├── overlays/       # nixpkgs overlays/patches
├── nix/            # core nix expressions
├── inventory/      # host inventory
├── examples/       # example configs
├── .flox/          # flox dev environments
└── flake.nix       # entry point
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Add shared module | modules/.common.d/ | consumed by darwin & nixos |
| Darwin-only config | modules/darwin/ | feature.nix + .d/ assets |
| NixOS-only config | modules/nixos/ | |
| Home Manager config | modules/home-manager/ | |
| New host | hosts/<name>/ | follow bioskop/nikopol |
| Documentation | docs/*.adoc | AsciiDoc only |
| Catalog data | catalog/ | drives ndh.context.catalog |
| Go helpers | packages/ | |
| Package wrappers/tests | pkgs/ | bats |
| Overlays/patches | overlays/ | |

## CONVENTIONS
- Nix: 2-space indent, max 200 chars/line.
- Shell scripts: POSIX-compliant; no tabs.
- Docs: AsciiDoc only (no Markdown in docs/).
- Module layout: feature.nix + optional feature.d/ for assets/tests.
- Tests: bats in pkgs/ and modules/*/.d/tests; run via `nix flake check`.
- Secrets via sops-nix; never commit plaintext.
- Profile roles: bringup / system / user; Home Manager disabled in bringup.
- Shared logic prefers modules/.common.d; guard platform bits with isNixosPlatform.
- Hosts import modules/ + profile; shared logic in host-common.nix.

## ANTI-PATTERNS (THIS PROJECT)
- Do not mix Markdown in docs/.
- Do not edit flake.lock by hand; use `nix flake update`.
- Do not commit secrets (.secrets is sops-encrypted).
- Avoid tabs in shell scripts.
- Don't duplicate logic between .common.d and platform dirs; prefer .common.d.

## UNIQUE STYLES
- Modules use ndh.context (catalog, inventory, hostProfile) for data-driven config.
- Flake inputs flow through flake-commons aggregator (indirect ids).
- Operator tools require arming (ndh-ops arm) before use.

## COMMANDS
```bash
nix flake check          # validate
nix develop              # dev shell
nix build                # build
nixos-rebuild switch     # apply (nixos)
darwin-rebuild switch     # apply (darwin)
nix fmt                  # format (treefmt)
nvfetcher                # fetch external packages
```

## NOTES
- `result` symlink = last build (gitignored).
- .flox/env provides dev environment.
- AGENTS.root.md is legacy; AGENTS.md is canonical.
