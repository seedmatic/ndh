---
name: nix-darwin-home
description: >-
  Expert knowledge of the nix-darwin-home repository: architecture, module system,
  ndh.store API, script bundling conventions, Lima/Tart VM materializers, ZFS integration,
  naming conventions, and flake outputs. Use when: working on nix-darwin-home modules,
  adding scripts, configuring VMs, debugging flake evaluation, understanding how hosts/profiles
  compose, or applying ndh conventions. Triggers: nix-darwin-home, ndh.store, Lima VM,
  Tart VM, ZFS NixOS, io.nxmatic, bringup image, installBinScript, writeShellScriptBin,
  ndhStoreApi, mkHostOutputs, Lima materializer, tart materializer.
---

# nix-darwin-home Repository Knowledge

## Purpose

Single-root Nix flake managing **macOS (Darwin) + NixOS VM** configurations for hosts
bioskop and nikopol. Darwin orchestrates NixOS guests via Lima (QEMU/VZ) and Tart (VZ)
VM materializers. All secrets via SOPS/age. No per-host flakes — one `flake.nix` at root.

## Repository Layout

```
flake.nix                   # Root: all outputs, mkNdhStoreApiFor, mkHostOutputs
modules/
  .common.d/                # Shared (Darwin + NixOS): ndhStore API, logger, trampoline
    default.nix             # Defines ndh.store (injected as special arg to all modules)
    shell.d/                # logger.sh, nix-bash-trampoline.sh, post-activation.sh
    ssh/                    # SSH key management scripts
  darwin/                   # macOS-specific modules
    lima-config.nix         # Lima VM configuration generator
    tart-config.nix         # Tart VM materializer
    outputs.nix             # mkDarwinConfig / mkDarwinOutputs
  nixos/
    zfs.nix                 # ZFS overlays, ESP sync, initrd scripts, shutdown ramfs
    outputs.nix             # mkNixosConfig / mkNixosOutputs
    systemd/                # Custom systemd unit modules
  home-manager/             # Home Manager modules (shared profiles)
profiles/                   # .common.nix (base options), committed.nix
hosts/                      # Per-host configs: bioskop/, nikopol/
catalog/default.nix         # Central data: users, networks (lan/tailnet), clusters
inventory/default.nix       # Host form (baremetal/vm), VM provider, builder specs
overlays/                   # Nixpkgs overlays (bird, qemu, direnv, incus-compose…)
pkgs/                       # Custom derivations (tart-guest-agent)
sandbox/                    # VM working directory (disk images, manifests)
```

## ndh.store API — The Core Convention

**All** externalized scripts must use `ndh.store.*` (not bare `pkgs.writeShellScript`
or `pkgs.replaceVars`). This ensures the `io.nxmatic.nix-darwin-home-` prefix on every
derivation, so scripts are traceable to their owning package.

### Full API (available as `ndh.store.*` in all modules)

| Function | Signature | Output |
|----------|-----------|--------|
| `prefix` | `string` | `"io.nxmatic.nix-darwin-home"` |
| `prefixedName` | `name → string` | `"io.nxmatic.nix-darwin-home-${name}"` (idempotent) |
| `writeShellScript` | `name: text` | Bare script at `$out` (prefixed drv name) |
| `writeShellScriptBin` | `name: text` | `$out/bin/<name>` (prefixed drv name) |
| `installScript` | `{ name, source, mode? }` | Bare file at `$out` via `install -m <mode>` |
| `installBinScript` | `name: source` | `$out/bin/<name>` wrapping pre-built source |
| `runCommand` | `name: attrs: text` | `runCommand (prefixedName name) attrs text` |
| `writeText` | `name: text` | `writeText (prefixedName name) text` |
| `lookupScript` | — | Store-asset-lookup.sh for runtime discovery |
| `lookupPackage` | — | CLI wrapper for store-asset-lookup |

**Defined in two places** (must keep in sync):
- `modules/.common.d/default.nix` → `ndhStore = rec { ... }` (used via `ndh.store` special arg)
- `flake.nix:mkNdhStoreApiFor` → `ndhStoreApiLinux` / `ndhStoreApiDarwin` (used for `ndh.store` injected at flake level into NixOS/Darwin modules)

### Script Bundling Rules

```nix
# ❌ WRONG — bare file at Nix store root
pkgs.writeShellScript "my-script" text
pkgs.replaceVars ./script.sh { ... }           # without wrapping!

# ✅ CORRECT — scripts with inline text
ndh.store.writeShellScript "my-script" text    # bare $out (for source/initrd use)
ndh.store.writeShellScriptBin "my-tool" text   # $out/bin/my-tool (for exec use)

# ✅ CORRECT — scripts from external .sh files (via replaceVars)
ndh.store.installBinScript "my-tool" (pkgs.replaceVars ./my-tool.sh { var = val; })

# ✅ CORRECT — installScript for bare file (e.g. shutdown ramfs, initrd)
ndh.store.installScript { name = "zpool-sync"; source = pkgs.replaceVars ...; mode = "0755"; }
```

**When to use `installScript` vs `installBinScript`:**
- `installScript` → when the caller needs the file directly as `${drv}` (initrd `storePaths`,
  `shutdownRamfs.contents[...].source`, scripts that are `source`d at runtime)
- `installBinScript` → everything else (ExecStart, activation text, launchd scripts)

**String alias pattern** (when a script path is passed as `@placeholder@` via `pkgs.replaceVars inherit`):
```nix
# The pkg holds the bin/, but the variable stays a string for transparent inherit:
bioskopFstabPkg    = ndh.store.installBinScript "bioskop-fstab" (pkgs.replaceVars ...);
bioskopFstabScript = "${bioskopFstabPkg}/bin/bioskop-fstab";  # string for replaceVars
```

## Flake Architecture

### mkNdhStoreApiFor (flake.nix:110–152)

Returns a store-prefixing API for a given `pkgsForSystem`:
- `ndhStoreApiDarwin` = mkNdhStoreApiFor pkgsForDarwin
- `ndhStoreApiLinux`  = mkNdhStoreApiFor pkgsForLinux
- Both passed as `ndhStoreApi` / `ndhStore` special arg into module special args

### mkHostOutputs

For each host entry in `inventory/`:
- Generates `darwinConfigurations.<host>`
- Generates `nixosConfigurations.<host>-nixos`, `<host>-nixos-lima`, `<host>-nixos-tart`
- Generates `packages.<system>.<host>-nixos-{lima,tart}-vm-materialize`
- Generates `vmConfigurations.{lima,tart,selected}` aliases

### generationMode

Special arg passed to NixOS configs:
- `"bringup"` → disk image build; home-manager disabled; interactive boot
- `"full"` / `"runtime"` → normal system; home-manager enabled

## Module System

**Special args** available to all modules:
```nix
{ ndh, lib, pkgs, config, ... }
# ndh.store     → ndh.store API (writeShellScriptBin, installBinScript, etc.)
# ndh.vm        → VM provider info (provider = "lima"|"tart")
# lib           → nixpkgs lib
```

**Module layers** (composed by mkBaseModulesFor):
1. `preModules` — host-specific overrides
2. `baseModules` — nixpkgs/darwin standard modules
3. Platform modules — `modules/darwin/` or `modules/nixos/`
4. `extraModules` — profile + host-specific additions

## Lima VM Materializer (modules/darwin/lima-config.nix)

Generates lima.yaml + materialize script. Key flow:
1. `nixosDiskImageBringupSystemdZfs` path injected from flake as bringup image
2. Materializer copies ZFS disk images → `$HOME/.lima/vms/<name>/`
3. Lima config: VZ/QEMU, 3 networks (vzNAT/shared/bridged), additional ZFS disks
4. Additional disks labeled `zpool=<pool>` to match `modules/nixos/zfs-pool-disk-map.nix`
5. Gcroot at `~/.local/share/nix/gcroots/` keeps derivations alive

## Tart VM Materializer (modules/darwin/tart-config.nix)

1. Bringup image resolves from **gcroot manifest** (stored in user gcroots after activation)
2. `boot.img` → root disk (ASIF format for Tart)
3. Extra data disks derive names from bringup manifest
4. Non-ZFS data disks reset to blank on activation
5. Run script: `~/.tart/vms/<name>.sh`

## ZFS Integration (modules/nixos/zfs.nix)

Key components:
- **`zfsOverlays.enable`** — enables overlay-mounted `/nix/store` over ZFS tank
- **`stage2ZpoolInitDevicesCheckPackage`** — checks vdev devices pre-import
- **`stage2ZpoolInitPackage`** — imports + mounts zpools in stage-2
- **`espSyncServicePackage`** — syncs /boot/efi-boot → secondary ESPs
- **`zpoolSyncExportShutdownScript`** — exports zpools in shutdown ramfs
- **`initrdBootEntryReconcileScript`** — EFI boot entry reconciliation in initrd
- Scripts embedded in initrd via `boot.initrd.systemd.storePaths`
- Shutdown ramfs script via `systemd.shutdownRamfs.contents`

## Naming Conventions

| Pattern | Convention |
|---------|-----------|
| Nix store derivation names | `io.nxmatic.nix-darwin-home-<name>` (via `ndh.store.prefixedName`) |
| Lima VM hostname | `nerd-nixos` (from hostAlias) |
| Disk images | `<vmName>-<pool>.img` |
| Gcroot links | `~/.local/share/nix/gcroots/<name>` |
| Packages (flake) | `<hostAlias>-nixos-{lima,tart}-vm-materialize` |
| NixOS configs | `<mainName>-nixos`, `<mainName>-nixos-{lima,tart}` |

## Common Pitfalls

1. **`installBinScript` missing** — if NixOS modules can't find it, the definition in
   `flake.nix:mkNdhStoreApiFor` is the authoritative one (not just `modules/.common.d/default.nix`)
2. **`installScript` calling convention** — always uses attrset `{ name, source, mode? }`,
   not curried `"name" { ... }`
3. **Scripts sourced vs exec'd** — scripts used via `source ${path}` or in `shutdownRamfs`
   must use `installScript` (bare file), not `installBinScript`
4. **`nix flake check --no-build`** uses committed state — staged but uncommitted changes
   won't be picked up; must commit before re-checking
5. **`bringup-zfs-disk-image.nix`** has no `ndh` arg — use manual
   `pkgs.runCommand "io.nxmatic.nix-darwin-home-<name>"` there

## References

- [`flake.nix`](../../flake.nix) — mkNdhStoreApiFor, mkHostOutputs, vmConfigurations
- [`modules/.common.d/default.nix`](../../modules/.common.d/default.nix) — ndhStore API
- [`modules/darwin/lima-config.nix`](../../modules/darwin/lima-config.nix) — Lima materializer
- [`modules/darwin/tart-config.nix`](../../modules/darwin/tart-config.nix) — Tart materializer
- [`modules/nixos/zfs.nix`](../../modules/nixos/zfs.nix) — ZFS overlays + boot integration
- [`catalog/default.nix`](../../catalog/default.nix) — users, networks, clusters
- [`inventory/default.nix`](../../inventory/default.nix) — host form factors, VM providers
