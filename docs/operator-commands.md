# Operator Commands (@codebase)

This document defines the canonical operator-facing command model.

## Principles

- Internal implementation scripts can remain colocated with modules.
- Operator entrypoints are exposed as short commands from Nix packages/apps.
- Canonical operator command prefix is `ndh-`.
- Avoid exposing internal `io-nxmatic-*` script names in `bin/`.

## Canonical Commands

- `ndh-bringup-install`
  - Purpose: install/refresh the NDH bringup runtime profile.
  - Flake app/package attribute: `ndh-bringup-install`.

- `ndh-vm-lima-materialize`
  - Purpose: materialize Lima VM config and image links in the host profile.
  - Flake app/package attribute: `ndh-vm-lima-materialize`.

- `ndh-vm-tart-materialize`
  - Purpose: materialize Tart raw/ASIF image links in the host profile.
  - Flake app/package attribute: `ndh-vm-tart-materialize`.

- `ndh-log-capture`
  - Purpose: run a command, stream output to console, and save a timestamped log file (default under `/tmp`).
  - Flake app/package attribute: `ndh-log-capture`.

## Tart Disk Image Rematerialization (@codebase)

Use this procedure when you need to manually regenerate Tart VM disk images
outside of darwin activation.

- Standard rematerialization (rebuild root image, create missing data disks):
  - `nix run .#ndh-vm-tart-materialize`
  - or `nix run /private/var/lib/git/nxmatic/nix-darwin-home#ndh-vm-tart-materialize`

- Recommended pre-step before rematerialization:
  - `tart stop nerd-nixos || true`

- Full reset rematerialization (recreate VM + all data disks):
  - One-command factory reset mode:
   - `NDH_TART_FACTORY_RESET=1 nix run .#ndh-vm-tart-materialize`
  - Equivalent manual sequence:
   1. Stop VM: `tart stop nerd-nixos || true`
   2. Remove VM and data disks:
     - `rm -rf ~/.tart/vms/nerd-nixos`
     - `rm -rf ~/.tart/disks/nerd-nixos`
   3. Re-run materializer:
     - `nix run .#ndh-vm-tart-materialize`

- Notes:
  - Root disk is always rematerialized from the configured raw source.
  - Data disks (`tank1`, `tank2`, `tank3`, `recover`) are created if missing.
  - `NDH_TART_FACTORY_RESET` accepts truthy values: `1`, `true`, `yes`, `on`.
    When enabled, the materializer removes existing root/data images before rebuilding.
  - To refresh only selected data disks, delete just those `~/.tart/disks/nerd-nixos/*.asif` files and run `nix run .#ndh-vm-tart-materialize`.

## Command Output Capture Helper (@codebase)

Use this helper instead of manually appending `| tee /tmp/...` each time.

- Generic usage:
  - `nix run .#ndh-log-capture -- <command> [args...]`

- Example (capture a Nix build):
  - `nix run .#ndh-log-capture -- nix build .#darwinConfiguration.system -L -v -v`

- Optional naming/location:
  - `nix run .#ndh-log-capture -- --name darwin-rebuild --dir /tmp -- nix build .#darwinConfiguration.system -L -v -v`

- Environment defaults:
  - `NDH_CAPTURE_DIR` (default `/tmp`)
  - `NDH_CAPTURE_NAME` (default derived from command name)

The helper preserves the wrapped command's exit code and prints the created log path at the end.

### Preferred Nix command workflow (@codebase)

When running Nix operations you may want to review with Copilot later, prefer wrapping
them with `ndh-log-capture` so logs are consistently archived in `/tmp`.

- Capture `nix build`:
  - `nix run .#ndh-log-capture -- --name nix-build-darwin -- nix build .#darwinConfiguration.system -L -v -v`

- Capture `nix run`:
  - `nix run .#ndh-log-capture -- --name tart-materialize -- env NDH_TART_FACTORY_RESET=1 nix run .#ndh-vm-tart-materialize`

- Capture `nixos-rebuild`:
  - `nix run .#ndh-log-capture -- --name nixos-rebuild-boot -- sudo nixos-rebuild boot --flake .#tart-bioskop-bringup-grub-zfs -L`

This replaces ad-hoc `2>&1 | tee /tmp/...` usage while keeping the same live terminal output behavior.

## Tart Serial Console Path Override (@codebase)

Generated Tart run wrapper now supports stable serial endpoint override.

- Default wrapper behavior:
  - If no `NDH_TART_SERIAL_PATH` is provided, wrapper uses Tart `--serial` default behavior.
  - Auto PTY bridge is opt-in via `NDH_TART_SERIAL_BRIDGE_ENABLE=1`.
  - `--serial-path` (including auto bridge) is safety-gated and disabled by default due known Tart/VZ regressions.
  - To force serial-path anyway, set `NDH_TART_SERIAL_PATH_UNSAFE_ALLOW=1`.

- Optional auto bridge behavior (opt-in):
  - Enable with: `NDH_TART_SERIAL_PATH_UNSAFE_ALLOW=1 NDH_TART_SERIAL_BRIDGE_ENABLE=1 ~/.tart/vms/nerd-nixos.sh`
  - Wrapper creates PTY bridge with `socat` under `~/.tart/serial`.
  - Tart endpoint: `~/.tart/serial/nerd-nixos.tart`
  - Screen endpoint: `~/.tart/serial/nerd-nixos.screen`
  - Wrapper prints exact `screen` attach command on startup.

- Runtime override:
  - `NDH_TART_SERIAL_PATH=/dev/ttys003 ~/.tart/vms/nerd-nixos.sh`

- Bridge tuning overrides:
  - `NDH_TART_SERIAL_ENABLE=0|1`
  - `NDH_TART_SERIAL_PATH_UNSAFE_ALLOW=0|1`
  - `NDH_TART_SERIAL_BRIDGE_ENABLE=0|1`
  - `NDH_TART_SERIAL_BRIDGE_DIR=~/.tart/serial`
  - `NDH_TART_SERIAL_BRIDGE_NAME=nerd-nixos`

- Behavior:
  - If `NDH_TART_SERIAL_PATH` points to an existing endpoint and `NDH_TART_SERIAL_PATH_UNSAFE_ALLOW=1`, wrapper uses `--serial-path=<path>`.
  - If path is missing, wrapper logs warning and falls back to `--serial`.
  - If serial-path is not explicitly unsafe-allowed, wrapper logs warning and uses `--serial`.
  - If `NDH_TART_SERIAL_PATH` is unset and bridge is disabled or fails, wrapper uses `--serial`.

- Tip:
  - Use a deterministic external endpoint path when possible, then attach `screen` to that same endpoint.

## Darwin Configuration Selectors (@codebase)

For each host, Darwin outputs expose one selected default plus explicit VM flavor variants:

- `{host}`
  - Selected default Darwin configuration.
  - Provider is controlled by `hosts/<host>/default.nix` via `hostProfile.vmProvider`.

- `{host}-lima`
  - Explicit Darwin configuration aligned with Lima runtime (`<host>-nixos-lima`).

- `{host}-tart`
  - Explicit Darwin configuration aligned with Tart runtime (`<host>-nixos-tart`).

Examples:

- `bioskop`
- `bioskop-lima`
- `bioskop-tart`

## Migration Rules

1. Add/keep internal scripts under module-local `*.d/` folders.
2. Expose only stable wrappers as operator commands.
3. Name wrappers with short, task-oriented names (`ndh-<domain>-<action>`).
4. Prefer one operator tool surface over per-script ad-hoc names.

## Follow-up Candidates

- `ndh-ssh-keys-enrich`
